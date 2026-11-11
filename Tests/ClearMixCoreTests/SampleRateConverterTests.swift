import XCTest
@testable import ClearMixCore

final class SampleRateConverterTests: XCTestCase {
    private let halfTaps = 16

    private func sine(frequency: Double, sampleRate: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    func testSameRateIsTransparent() {
        let input = sine(frequency: 440, sampleRate: 48_000, frames: 2_000)
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 48_000)
        let output = converter.process(input)

        XCTAssertEqual(output.count, input.count - halfTaps + 1)
        for index in 0..<output.count {
            XCTAssertEqual(output[index], input[index], accuracy: 1e-5)
        }
    }

    func testUpsamplingLength() {
        let converter = SampleRateConverter(inputRate: 8_000, outputRate: 48_000)
        let output = converter.process(sine(frequency: 1_000, sampleRate: 8_000, frames: 8_000))
        let expected = (8_000 - halfTaps) * 6
        XCTAssertLessThanOrEqual(abs(output.count - expected), 2, "got \(output.count)")
    }

    func testUpsamplingReconstructsSineAccurately() {
        let inputRate = 8_000.0
        let outputRate = 48_000.0
        let frequency = 1_000.0
        let input = sine(frequency: frequency, sampleRate: inputRate, frames: 8_000)

        let converter = SampleRateConverter(inputRate: inputRate, outputRate: outputRate)
        let output = converter.process(input)
        XCTAssertGreaterThan(output.count, 40_000)

        // Output n sits at input position n * (inRate/outRate).
        let step = inputRate / outputRate
        var signal: Double = 0
        var error: Double = 0
        var count = 0
        for index in 2_000..<(output.count - 2_000) {
            let position = Double(index) * step
            let reference = sin(2 * Double.pi * frequency * position / inputRate)
            let difference = Double(output[index]) - reference * 0.5
            signal += reference * reference * 0.25
            error += difference * difference
            count += 1
        }
        let snr = 10 * log10(signal / max(error, 1e-24))
        XCTAssertGreaterThan(snr, 70, "reconstruction SNR was \(snr) dB for \(count) samples")
    }

    func testDownsamplingReconstructsSineAccurately() {
        let inputRate = 48_000.0
        let outputRate = 44_100.0
        let frequency = 1_000.0
        let input = sine(frequency: frequency, sampleRate: inputRate, frames: 48_000)

        let converter = SampleRateConverter(inputRate: inputRate, outputRate: outputRate)
        let output = converter.process(input)
        XCTAssertGreaterThan(output.count, 44_000)

        let step = inputRate / outputRate
        var signal: Double = 0
        var error: Double = 0
        for index in 2_000..<(output.count - 2_000) {
            let position = Double(index) * step
            let reference = sin(2 * Double.pi * frequency * position / inputRate)
            let difference = Double(output[index]) - reference * 0.5
            signal += reference * reference * 0.25
            error += difference * difference
        }
        let snr = 10 * log10(signal / max(error, 1e-24))
        XCTAssertGreaterThan(snr, 65, "reconstruction SNR was \(snr) dB")
    }

    /// Feeding the converter in small blocks must not change the result.
    func testBlockProcessingMatchesSingleCall() {
        let input = sine(frequency: 440, sampleRate: 44_100, frames: 4_410)
        let single = SampleRateConverter(inputRate: 44_100, outputRate: 48_000)
        let expected = single.process(input)

        let chunked = SampleRateConverter(inputRate: 44_100, outputRate: 48_000)
        var chunkedOutput: [Float] = []
        var offset = 0
        while offset < input.count {
            let length = min(480, input.count - offset)
            let block = Array(input[offset..<(offset + length)])
            chunkedOutput.append(contentsOf: chunked.process(block))
            offset += length
        }

        XCTAssertEqual(chunkedOutput.count, expected.count)
        for index in 0..<expected.count {
            XCTAssertEqual(chunkedOutput[index], expected[index], accuracy: 1e-6)
        }
    }

    func testDriftChangesConversionRatio() {
        let input = sine(frequency: 440, sampleRate: 48_000, frames: 48_000)
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 48_000)
        converter.setDriftPPM(1_000)  // 0.1 %
        let output = converter.process(input)
        XCTAssertLessThan(output.count, input.count)
        XCTAssertGreaterThan(output.count, input.count - 200)
    }

    func testResetClearsState() {
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 48_000)
        _ = converter.process(sine(frequency: 440, sampleRate: 48_000, frames: 1_000))
        converter.reset()
        let tail = converter.process([0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(tail.allSatisfy { abs($0) < 1e-6 })
    }
}
