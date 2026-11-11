import XCTest
@testable import ClearMixCore

final class LinearResamplerTests: XCTestCase {
    private func run(_ input: [Float], step: Double, chunk: Int? = nil) -> [Float] {
        var resampler = LinearResampler()
        var output: [Float] = []
        let inputChunk = chunk ?? input.count
        let capacity = LinearResampler.maxOutputFrames(inputFrames: inputChunk, step: step)
        var buffer = [Float](repeating: 0, count: capacity)
        var offset = 0
        while offset < input.count {
            let frames = min(inputChunk, input.count - offset)
            input.withUnsafeBufferPointer { source in
                buffer.withUnsafeMutableBufferPointer { destination in
                    let written = resampler.process(
                        source.baseAddress! + offset,
                        frames: frames,
                        step: step,
                        output: destination.baseAddress!,
                        capacity: destination.count
                    )
                    output.append(contentsOf: destination[0..<written])
                }
            }
            offset += frames
        }
        return output
    }

    func testUnityStepPassesSignalThroughUnchanged() {
        let input = (0..<64).map { Float($0) / 64 }
        let output = run(input, step: 1)
        // One frame of interpolation delay at the start, none at the end.
        XCTAssertEqual(output.count, input.count - 1)
        XCTAssertEqual(output, Array(input.dropLast()))
    }

    func testUnityStepIsIndependentOfChunkSize() {
        let input = (0..<64).map { sinf(Float($0) * 0.1) }
        let single = run(input, step: 1)
        let chunked = run(input, step: 1, chunk: 7)
        XCTAssertEqual(single.count, chunked.count)
        for index in 0..<single.count {
            XCTAssertEqual(single[index], chunked[index], accuracy: 1e-6)
        }
    }

    func testHalvingStepDoublesTheFrames() {
        let input = (0..<32).map { Float($0) }
        let output = run(input, step: 0.5)
        XCTAssertEqual(Double(output.count), 62, accuracy: 2)
        for index in stride(from: 0, to: output.count - 1, by: 2) {
            XCTAssertEqual(output[index], Float(index / 2), accuracy: 1e-5)
        }
    }

    func testStepAboveOneProducesFewerFrames() {
        let input = (0..<1_000).map { sinf(Float($0) * 0.05) }
        let output = run(input, step: 1.002, chunk: 160)
        let expected = Double(input.count) / 1.002
        XCTAssertEqual(Double(output.count), expected, accuracy: 2)
    }

    func testDriftRatioKeepsSignalContinuous() {
        // A slow sine resampled by 0.1 % must stay within a hair of the ideal
        // sine at the matching phase; no clicks, no discontinuities.
        let input = (0..<2_000).map { sinf(Float($0) * 2 * .pi * 100 / 48_000) }
        let output = run(input, step: 1.001, chunk: 160)
        var previous = output[0]
        for sample in output.dropFirst() {
            XCTAssertLessThan(abs(sample - previous), 0.05)
            previous = sample
        }
    }

    func testResetRestoresInitialState() {
        var resampler = LinearResampler()
        let input = [Float](repeating: 0.5, count: 16)
        var output = [Float](repeating: 0, count: 32)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let first = resampler.process(
                    source.baseAddress!, frames: 16, step: 1.5,
                    output: destination.baseAddress!, capacity: destination.count
                )
                XCTAssertGreaterThan(first, 0)
                XCTAssertTrue(resampler.hasPending)
                resampler.reset()
                XCTAssertFalse(resampler.hasPending)
                XCTAssertEqual(resampler.fraction, 0)
                let second = resampler.process(
                    source.baseAddress!, frames: 16, step: 1,
                    output: destination.baseAddress!, capacity: destination.count
                )
                XCTAssertEqual(second, 15)
            }
        }
    }
}
