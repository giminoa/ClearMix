import XCTest
@testable import ClearMixCore

final class MicChainTests: XCTestCase {
    private func noise(
        frames: Int,
        channels: Int,
        amplitude: Float = 0.05,
        seed: UInt64 = 7
    ) -> [Float] {
        var state = seed
        var samples = [Float](repeating: 0, count: frames * channels)
        for index in 0..<samples.count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            samples[index] = (unit * 2 - 1) * amplitude
        }
        return samples
    }

    func testDriftPathKeepsUpWithTheCaptureStream() throws {
        let chain = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        chain.targetFillFrames = 960
        chain.gain.setGain(decibels: -20)

        let block = [Float](repeating: 0.1, count: 512)
        var out = [Float](repeating: 0, count: 512)
        var consumed = 0
        var produced = 0
        for _ in 0..<400 { // ~4.3 s
            // Ring is far above target, so the controller asks for a fast drain.
            chain.setCaptureFill(12_000)
            _ = block.withUnsafeBufferPointer { source in
                chain.process(source.baseAddress!, frames: block.count)
            }
            consumed += block.count
            out.withUnsafeMutableBufferPointer { destination in
                produced += chain.pull(into: destination.baseAddress!, maxFrames: destination.count)
            }
        }

        // At most the clamp (1 %) of frames is held back, plus the block tail.
        XCTAssertGreaterThan(produced, Int(Double(consumed) * 0.985))
        XCTAssertGreaterThan(chain.driftStep, 1.005)
    }

    func testChainProducesBlocksOnlyWhenFull() throws {
        let chain = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        chain.denoiseEnabled = false
        chain.limiter.ceilingDB = 0

        let source = [Float](repeating: 0.25, count: 400)
        _ = source.withUnsafeBufferPointer { buffer in
            chain.process(buffer.baseAddress!, frames: source.count)
        }
        // 400 frames is not a whole RNNoise block: nothing is finished yet.
        XCTAssertEqual(chain.pendingCount, 0)

        let rest = [Float](repeating: 0.25, count: 400)
        _ = rest.withUnsafeBufferPointer { buffer in
            chain.process(buffer.baseAddress!, frames: rest.count)
        }
        // 800 frames in, exactly one 480-frame block completed.
        XCTAssertEqual(chain.pendingCount, MicChain.blockSize)
    }

    func testStereoInputIsDownmixedToMono() throws {
        let chain = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 2))
        chain.denoiseEnabled = false
        chain.limiter.ceilingDB = 0

        let frames = MicChain.blockSize * 200
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            interleaved[frame * 2] = 0.4
            interleaved[frame * 2 + 1] = 0.2
        }
        let output = chain.processOffline(interleaved)

        // Average of the two channels. The first half second is skipped because
        // the gate fades in from silence when the chain starts.
        let middle = output.dropFirst(24_000).dropLast(64)
        XCTAssertFalse(middle.isEmpty)
        for sample in middle {
            XCTAssertEqual(sample, 0.3, accuracy: 0.005)
        }
    }

    func testResampledOutputHasRequestedLength() throws {
        let chain = try XCTUnwrap(MicChain(inputSampleRate: 44_100, channels: 1))
        chain.denoiseEnabled = false
        let input = noise(frames: 44_100, channels: 1)
        let output = chain.processOffline(input, chunkFrames: 512)

        // One second in should be roughly one second out (48 000 frames), losing
        // only the blocks still waiting for their last samples.
        XCTAssertGreaterThan(output.count, 47_000)
        XCTAssertLessThanOrEqual(output.count, 48_000)
    }

    func testDenoiseLowersStationaryNoise() throws {
        let plain = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        plain.denoiseEnabled = false
        let denoised = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        denoised.denoiseEnabled = true
        denoised.limiter.ceilingDB = 0
        plain.limiter.ceilingDB = 0

        let input = noise(frames: 48_000 * 2, channels: 1)
        let before = plain.processOffline(input)
        let after = denoised.processOffline(input)

        func rms(_ samples: ArraySlice<Float>) -> Double {
            var sum = 0.0
            for sample in samples { sum += Double(sample) * Double(sample) }
            return (sum / Double(samples.count)).squareRoot()
        }

        // Skip the first half second: RNNoise's recurrent state needs to settle.
        let range = (before.count / 2)..<before.count
        let reduction = 20 * log10(rms(before[range]) / max(rms(after[range]), 1e-9))
        XCTAssertGreaterThan(reduction, 6, "expected >6 dB of suppression, got \(reduction) dB")
    }

    func testLimiterCeilingIsRespected() throws {
        let chain = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        chain.denoiseEnabled = false
        chain.gain.setGain(decibels: 0)
        chain.gain.snapToTarget()
        chain.limiter.ceilingDB = -6

        let input = noise(frames: MicChain.blockSize * 8, channels: 1, amplitude: 0.9)
        let output = chain.processOffline(input)
        let ceiling = AudioMath.dbToLinear(-6)
        for sample in output {
            XCTAssertLessThanOrEqual(abs(sample), ceiling + 1e-4)
        }
    }

    func testZeroStrengthAndABBypassLeaveSignalUndenoised() throws {
        let plain = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        plain.denoiseEnabled = false
        plain.limiter.ceilingDB = 0

        let zeroStrength = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        zeroStrength.denoiseEnabled = true
        zeroStrength.denoiseStrength = 0
        zeroStrength.limiter.ceilingDB = 0

        let raw = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        raw.denoiseEnabled = false
        raw.gate.isEnabled = false
        raw.abBypass = true
        raw.limiter.ceilingDB = 0

        let bypassed = try XCTUnwrap(MicChain(inputSampleRate: 48_000, channels: 1))
        bypassed.denoiseEnabled = true
        bypassed.gate.isEnabled = true
        bypassed.gate.thresholdDB = 0 // gate would silence everything if not bypassed
        bypassed.abBypass = true
        bypassed.limiter.ceilingDB = 0

        let input = noise(frames: MicChain.blockSize * 12, channels: 1, amplitude: 0.1)
        let ref = plain.processOffline(input)
        XCTAssertEqual(zeroStrength.processOffline(input), ref)

        // With `abBypass` active, denoiser and gate are completely skipped regardless of their settings.
        let bypassedOut = bypassed.processOffline(input)
        XCTAssertEqual(bypassedOut, raw.processOffline(input))

        // After the 5 ms gate startup ramp in `plain` settles, `bypassedOut` also matches `ref`.
        for (a, b) in zip(bypassedOut.dropFirst(2_400), ref.dropFirst(2_400)) {
            XCTAssertEqual(a, b, accuracy: 1e-4)
        }
    }
}
