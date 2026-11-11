import Accelerate
import Foundation

/// One application's slider: gain with a click-free ramp, mute, a peak meter and
/// a ceiling that stops a boost from clipping the device.
///
/// Everything is preallocated and `process` only touches scalars and the
/// caller's buffer, so it is safe to run from an audio render callback. Control
/// values are read with plain loads; a slider landing one callback late is
/// inaudible, and a lock or an allocation would not be.
public final class MixerBus: @unchecked Sendable {
    /// Linear gain currently applied.
    public private(set) var gain: Float = 1
    /// Gain the per-app slider is heading towards (0 when muted).
    public var targetGain: Float = 1
    /// Software master trim (0...1), combined with `targetGain` and ramped smoothly.
    public var masterGain: Float = 1
    /// Automatic ducking multiplier (0...1), combined with `targetGain` and ramped smoothly.
    public var duckingGain: Float = 1
    /// Peak of the most recent block, after gain and ceiling.
    public private(set) var peak: Float = 0
    /// Peak of the most recent block before the bus touched it.
    public private(set) var sourcePeak: Float = 0
    /// Seconds a gain change takes to complete. Short enough to feel immediate,
    /// long enough to avoid a click.
    public var rampSeconds: Float = 0.02
    /// Hard ceiling; a boost hits this instead of wrapping or clipping.
    public var ceiling: Float = 0.98

    public let equalizer: Equalizer
    public private(set) var isMuted = false
    private var preMuteGain: Float = 1

    private let sampleRate: Float
    private let rampStep: Float

    public init(sampleRate: Double) {
        self.sampleRate = Float(max(sampleRate, 1))
        equalizer = Equalizer(sampleRate: max(sampleRate, 1))
        rampStep = 1 / (self.sampleRate * max(rampSeconds, 0.001))
    }

    public var gainDB: Float {
        get { AudioMath.linearToDb(targetGain) }
        set { setGain(decibels: newValue) }
    }

    /// Slider gain in dB even while muted, so the UI keeps the user's knob position.
    public var unmutedGainDB: Float {
        AudioMath.linearToDb(isMuted ? preMuteGain : targetGain)
    }

    /// Linear gain as a percentage (0...400%), preserving slider position while muted.
    public var gainPercent: Float {
        (isMuted ? preMuteGain : targetGain) * 100
    }

    public func setGain(decibels: Float) {
        let linear = decibels <= -96 ? 0 : AudioMath.dbToLinear(decibels)
        let clamped = min(max(linear, 0), 4) // up to +12 dB (400%), then the ceiling
        preMuteGain = clamped > 0 ? clamped : preMuteGain
        targetGain = clamped
        isMuted = false
    }

    /// Sets linear gain directly from a 0...400% percentage slider.
    public func setGain(percent: Float) {
        let linear = min(max(percent / 100, 0), 4)
        if linear > 0 { preMuteGain = linear }
        targetGain = linear
        isMuted = false
    }

    public func mute() {
        if !isMuted && targetGain > 0 {
            preMuteGain = targetGain
        }
        isMuted = true
        targetGain = 0
    }

    public func unmute() {
        isMuted = false
        if targetGain == 0 {
            targetGain = preMuteGain > 0 ? preMuteGain : 1
        }
    }

    public func toggleMute() {
        isMuted ? unmute() : mute()
    }

    /// Applies EQ, smoothed gain/master/ducking, and ceiling to interleaved stereo frames in place.
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }

        var inputPeak: Float = 0
        vDSP_maxmgv(samples, 1, &inputPeak, vDSP_Length(frames * 2))
        sourcePeak = inputPeak

        equalizer.process(samples, frames: frames)

        let desired = targetGain * min(max(masterGain, 0), 1) * min(max(duckingGain, 0), 1)
        if gain == desired {
            if gain != 1 {
                var scale = gain
                vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(frames * 2))
            }
        } else {
            var current = gain
            let step = rampStep
            for frame in 0..<frames {
                let base = frame * 2
                samples[base] *= current
                samples[base + 1] *= current
                // Advance after applying, so the block starts at the gain the
                // last block ended with: no jump at a block boundary.
                let distance = desired - current
                if distance > 0 {
                    current = min(current + step, desired)
                } else if distance < 0 {
                    current = max(current - step, desired)
                }
            }
            gain = current
        }

        let ceiling = self.ceiling
        var low = -ceiling
        var high = ceiling
        vDSP_vclip(samples, 1, &low, &high, samples, 1, vDSP_Length(frames * 2))

        var outputPeak: Float = 0
        vDSP_maxmgv(samples, 1, &outputPeak, vDSP_Length(frames * 2))
        peak = outputPeak
    }

    public func snapToTarget() {
        gain = targetGain * min(max(masterGain, 0), 1) * min(max(duckingGain, 0), 1)
    }

    public func resetMeters() {
        peak = 0
        sourcePeak = 0
    }
}
