import XCTest
@testable import ClearMixCore

final class DenoiserTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Deterministic white noise so the measurements are reproducible.
    private func whiteNoise(frames: Int, amplitude: Float) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<frames).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 40) & 0xFFFF) / 32_767.5 - 1
            return unit * amplitude
        }
    }

    func testBlockSizeMatchesRNNoise() throws {
        let denoiser = try XCTUnwrap(Denoiser())
        XCTAssertEqual(denoiser.blockSize, 480)
        XCTAssertEqual(denoiser.sampleRate, 48_000)
        XCTAssertEqual(Denoiser.frameSize, denoiser.blockSize)
    }

    func testSilenceStaysSilent() throws {
        let denoiser = try XCTUnwrap(Denoiser())
        var block = [Float](repeating: 0, count: denoiser.blockSize)
        var peak: Float = 0
        for _ in 0..<10 {
            block.withUnsafeMutableBufferPointer { buffer in
                _ = denoiser.process(buffer.baseAddress!)
            }
            peak = max(peak, block.map(abs).max() ?? 0)
        }
        XCTAssertLessThan(peak, 1e-4)
    }

    func testSteadyNoiseIsAttenuated() throws {
        let denoiser = try XCTUnwrap(Denoiser())
        let frames = denoiser.blockSize * 60
        let noise = whiteNoise(frames: frames, amplitude: 0.05)
        var samples = noise

        samples.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset + denoiser.blockSize <= buffer.count {
                denoiser.process(buffer.baseAddress! + offset)
                offset += denoiser.blockSize
            }
        }

        // Ignore the first half: the recurrent model needs time to learn that
        // the noise floor is steady.
        let settled = denoiser.blockSize * 30
        let before = rms(Array(noise[settled...]))
        let after = rms(Array(samples[settled...]))
        let reduction = AudioMath.linearToDb(before) - AudioMath.linearToDb(after)
        XCTAssertGreaterThan(reduction, 6, "RNNoise should pull steady noise down noticeably")
    }

    func testPartialBufferProcessesOnlyWholeBlocks() throws {
        let denoiser = try XCTUnwrap(Denoiser())
        var samples = [Float](repeating: 0.1, count: 1_000)
        let consumed = samples.withUnsafeMutableBufferPointer { buffer in
            denoiser.process(buffer.baseAddress!, frames: buffer.count)
        }
        XCTAssertEqual(consumed, 960)
        XCTAssertEqual(Array(samples[960...]), [Float](repeating: 0.1, count: 40))
    }
}
