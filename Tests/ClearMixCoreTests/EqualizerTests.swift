import XCTest
@testable import ClearMixCore

final class EqualizerTests: XCTestCase {
    private func sine(frequency: Double, sampleRate: Double, frames: Int, amplitude: Float = 0.25) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * sinf(Float(2 * Double.pi * frequency * Double(frame) / sampleRate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    private func rms(_ samples: [Float], dropFrames: Int = 2_000) -> Double {
        let start = dropFrames * 2
        guard samples.count > start else { return 0 }
        var sum = 0.0
        for i in start..<samples.count {
            let s = Double(samples[i])
            sum += s * s
        }
        return (sum / Double(samples.count - start)).squareRoot()
    }

    func testFlatEqualizerIsTransparent() {
        let eq = Equalizer(sampleRate: 48_000)
        var samples = sine(frequency: 1_000, sampleRate: 48_000, frames: 4_096)
        let original = samples
        samples.withUnsafeMutableBufferPointer { buffer in
            eq.process(buffer.baseAddress!, frames: 4_096)
        }
        XCTAssertEqual(samples, original)
    }

    func testBoostingBandAmplifiesTargetFrequency() {
        let eq = Equalizer(sampleRate: 48_000)
        eq.setBand(5, gainDB: 6) // band 5 = 1000 Hz

        var samples = sine(frequency: 1_000, sampleRate: 48_000, frames: 8_192)
        let before = rms(samples)
        samples.withUnsafeMutableBufferPointer { buffer in
            eq.process(buffer.baseAddress!, frames: 8_192)
        }
        let after = rms(samples)
        let gainDB = 20 * log10(after / before)
        XCTAssertEqual(gainDB, 6.0, accuracy: 0.5)
    }

    func testCuttingBandAttenuatesTargetFrequency() {
        let eq = Equalizer(sampleRate: 48_000)
        eq.setBand(1, gainDB: -9) // band 1 = 64 Hz

        var samples = sine(frequency: 64, sampleRate: 48_000, frames: 12_000)
        let before = rms(samples, dropFrames: 4_000)
        samples.withUnsafeMutableBufferPointer { buffer in
            eq.process(buffer.baseAddress!, frames: 12_000)
        }
        let after = rms(samples, dropFrames: 4_000)
        let gainDB = 20 * log10(after / before)
        XCTAssertEqual(gainDB, -9.0, accuracy: 0.7)
    }

    func testGainClampsAndPresetsMatchBandCount() {
        let eq = Equalizer(sampleRate: 48_000)
        eq.setBand(0, gainDB: 50)
        XCTAssertEqual(eq.bands[0], Equalizer.maxGainDB)
        eq.setBand(0, gainDB: -50)
        XCTAssertEqual(eq.bands[0], Equalizer.minGainDB)

        for preset in Equalizer.Preset.allCases {
            XCTAssertEqual(preset.gainsDB.count, Equalizer.bandCount)
            eq.apply(preset: preset)
            XCTAssertEqual(eq.bands, preset.gainsDB)
        }
    }
}
