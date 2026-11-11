import XCTest
@testable import ClearMixCore

final class MixerBusTests: XCTestCase {
    private func makeStereo(frames: Int, value: Float) -> [Float] {
        [Float](repeating: value, count: frames * 2)
    }

    func testGainIsAppliedImmediatelyWhenItAlreadyMatches() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.targetGain = 0.5
        bus.snapToTarget()

        var samples = makeStereo(frames: 64, value: 0.4)
        samples.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 64)
        }

        XCTAssertEqual(samples[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(bus.peak, 0.2, accuracy: 1e-6)
    }

    func testGainChangeRampsAndReachesTarget() {
        let bus = MixerBus(sampleRate: 1_000) // 20 ms ramp = 20 frames
        bus.setGain(decibels: -6)

        // Half amplitude, so the 0.98 ceiling never interferes.
        var samples = makeStereo(frames: 100, value: 0.5)
        samples.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 100)
        }

        XCTAssertEqual(bus.gain, bus.targetGain, accuracy: 1e-6)
        XCTAssertEqual(samples[0], 0.5, accuracy: 1e-6, "ilk kare eski kazançta kalmalı")
        XCTAssertGreaterThan(samples[0], samples[40], "ramp aşağı inmeli")
        XCTAssertEqual(samples[80], samples[40], accuracy: 1e-6, "ramp sonrası sabit")
        XCTAssertEqual(samples[80], 0.5 * bus.targetGain, accuracy: 1e-6)
    }

    func testMuteRampsDownThenGoesSilent() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.mute()
        XCTAssertTrue(bus.isMuted)

        // The 20 ms ramp still passes the start of this block, by design.
        var rampBlock = makeStereo(frames: 4_800, value: 0.8)
        rampBlock.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 4_800)
        }
        XCTAssertEqual(bus.gain, 0, accuracy: 1e-6)
        XCTAssertEqual(rampBlock.last!, 0, accuracy: 1e-6)
        XCTAssertEqual(bus.peak, 0.8, accuracy: 1e-6, "rampa bloğun başında hâlâ duyulur")

        var mutedBlock = makeStereo(frames: 512, value: 0.8)
        mutedBlock.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 512)
        }
        XCTAssertEqual(bus.peak, 0, accuracy: 1e-6)
        XCTAssertTrue(mutedBlock.allSatisfy { $0 == 0 })

        bus.unmute()
        XCTAssertFalse(bus.isMuted)
        XCTAssertEqual(bus.targetGain, 1)
    }

    func testCeilingClampsBoost() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.targetGain = 4
        bus.snapToTarget()

        var samples = makeStereo(frames: 32, value: 0.5)
        samples.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 32)
        }

        XCTAssertEqual(bus.peak, bus.ceiling, accuracy: 1e-6)
        XCTAssertTrue(samples.allSatisfy { abs($0) <= bus.ceiling + 1e-6 })
    }

    func testSourcePeakIgnoresGainAndMute() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.mute()
        bus.snapToTarget()

        var samples = makeStereo(frames: 16, value: 0.3)
        samples.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 16)
        }

        XCTAssertEqual(bus.sourcePeak, 0.3, accuracy: 1e-6)
        XCTAssertEqual(bus.peak, 0, accuracy: 1e-6)
        XCTAssertLessThan(bus.gainDB, -100)
    }

    func testGainIsClampedToSaneRange() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.setGain(decibels: 40)
        XCTAssertEqual(bus.targetGain, 4, accuracy: 1e-6, "+12 dB üstü kırpılmalı")
        bus.setGain(decibels: -80)
        XCTAssertEqual(bus.targetGain, 0.0001, accuracy: 1e-6)
    }

    func testUnmuteRestoresPreMuteSliderGain() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.setGain(percent: 50)
        XCTAssertEqual(bus.targetGain, 0.5, accuracy: 1e-6)

        bus.mute()
        XCTAssertTrue(bus.isMuted)
        XCTAssertEqual(bus.targetGain, 0, accuracy: 1e-6)
        XCTAssertEqual(bus.gainPercent, 50, accuracy: 1e-3)

        bus.unmute()
        XCTAssertFalse(bus.isMuted)
        XCTAssertEqual(bus.targetGain, 0.5, accuracy: 1e-6)
    }

    func testMasterAndDuckingGainScaleOutput() {
        let bus = MixerBus(sampleRate: 48_000)
        bus.setGain(percent: 100)
        bus.masterGain = 0.5
        bus.duckingGain = 0.5
        bus.snapToTarget()

        var samples = makeStereo(frames: 64, value: 0.8)
        samples.withUnsafeMutableBufferPointer { buffer in
            bus.process(buffer.baseAddress!, frames: 64)
        }
        XCTAssertEqual(samples[0], 0.2, accuracy: 1e-6)
    }
}
