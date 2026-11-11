import XCTest
@testable import ClearMixCore

final class DynamicsTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func sine(frequency: Double, frames: Int, amplitude: Float) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func processed(_ input: [Float], _ stage: (UnsafeMutablePointer<Float>, Int) -> Void) -> [Float] {
        var samples = input
        samples.withUnsafeMutableBufferPointer { buffer in
            stage(buffer.baseAddress!, buffer.count)
        }
        return samples
    }

    // MARK: Gain

    func testGainAppliesTargetWhenSettled() {
        let gain = GainStage(sampleRate: sampleRate)
        gain.setGain(2)
        gain.snapToTarget()
        let output = processed([1, -1, 0.5], gain.process)
        XCTAssertEqual(output[0], 2, accuracy: 1e-6)
        XCTAssertEqual(output[1], -2, accuracy: 1e-6)
        XCTAssertEqual(output[2], 1, accuracy: 1e-6)
    }

    func testMuteRampsInsteadOfClicking() {
        let gain = GainStage(sampleRate: sampleRate, rampMilliseconds: 20)
        gain.setGain(1)
        gain.snapToTarget()
        gain.setGain(0)

        var samples = [Float](repeating: 1, count: 9_600)  // 200 ms
        samples.withUnsafeMutableBufferPointer { buffer in
            gain.process(buffer.baseAddress!, frames: buffer.count)
        }

        // The first sample is barely attenuated (no click) and the tail is silent.
        XCTAssertGreaterThan(samples[0], 0.9)
        XCTAssertEqual(samples.last!, 0, accuracy: 1e-3)
        XCTAssertFalse(gain.isRamping)
    }

    // MARK: Limiter

    func testLimiterKeepsBoostedSignalUnderCeiling() {
        let ceilingDB: Float = -1
        let limiter = SoftLimiter(sampleRate: sampleRate, ceilingDB: ceilingDB)
        let ceiling = AudioMath.dbToLinear(ceilingDB)

        let output = processed(sine(frequency: 1_000, frames: 24_000, amplitude: 2.0), limiter.process)
        let peak = output.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, ceiling + 1e-5)
        // Gain reduction must have engaged rather than clipping every peak.
        XCTAssertLessThan(limiter.gain, 0.5)
    }

    func testLimiterPassesQuietSignalUnchanged() {
        let limiter = SoftLimiter(sampleRate: sampleRate)
        let input = sine(frequency: 440, frames: 4_800, amplitude: 0.1)
        let output = processed(input, limiter.process)
        for index in input.indices {
            XCTAssertEqual(output[index], input[index], accuracy: 1e-6)
        }
        XCTAssertEqual(limiter.gain, 1, accuracy: 1e-6)
    }

    // MARK: Gate

    func testGateClosesOnSilence() {
        let gate = NoiseGate(sampleRate: sampleRate)
        gate.thresholdDB = -45
        var samples = [Float](repeating: 0, count: 24_000)
        samples.withUnsafeMutableBufferPointer { buffer in
            gate.process(buffer.baseAddress!, frames: buffer.count)
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertLessThan(gate.gain, 0.01)
        XCTAssertLessThan(samples.map { abs($0) }.max() ?? 0, 0.01)
    }

    func testGateOpensOnSpeechLevelTone() {
        let gate = NoiseGate(sampleRate: sampleRate)
        gate.thresholdDB = -45
        let input = sine(frequency: 300, frames: 4_800, amplitude: 0.1)  // -20 dBFS
        let output = processed(input, gate.process)
        XCTAssertTrue(gate.isOpen)

        // After the attack ramp the tone passes essentially untouched.
        let tail = Array(output[2_400...])
        let peak = tail.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.1, accuracy: 0.005)
    }

    func testGateClosesAfterHoldWhenSignalStops() {
        let gate = NoiseGate(sampleRate: sampleRate)
        gate.thresholdDB = -45
        var input = sine(frequency: 300, frames: 2_400, amplitude: 0.1)
        input.append(contentsOf: [Float](repeating: 0, count: 48_000))  // 1 s of silence
        let output = processed(input, gate.process)

        XCTAssertFalse(gate.isOpen)
        XCTAssertLessThan(output.last!.magnitude, 0.001)
    }

    func testDisabledGatePassesSilence() {
        let gate = NoiseGate(sampleRate: sampleRate)
        gate.isEnabled = false
        let output = processed([Float](repeating: 0, count: 4_800), gate.process)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    // MARK: Meter

    func testMeterReportsPeakAndRMS() {
        let meter = LevelMeter(sampleRate: sampleRate, decayDBPerSecond: 0)
        let input = sine(frequency: 1_000, frames: 48_000, amplitude: 0.5)
        input.withUnsafeBufferPointer { buffer in
            meter.process(buffer.baseAddress!, frames: buffer.count)
        }
        XCTAssertEqual(meter.peak, 0.5, accuracy: 0.01)
        // RMS of a sine is amplitude / sqrt(2) = -9 dBFS.
        XCTAssertEqual(meter.rmsDB, -9.03, accuracy: 0.2)
        XCTAssertEqual(meter.peakDB, -6.02, accuracy: 0.2)
    }

    func testDecibelConversionRoundTrip() {
        XCTAssertEqual(AudioMath.dbToLinear(0), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.dbToLinear(-6), 0.5012, accuracy: 1e-3)
        XCTAssertEqual(AudioMath.linearToDb(AudioMath.dbToLinear(-12)), -12, accuracy: 1e-4)
        XCTAssertEqual(AudioMath.dbToLinear(6), 1.9953, accuracy: 1e-3)
    }
}
