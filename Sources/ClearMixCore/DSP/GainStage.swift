import Accelerate
import Foundation

/// Smoothed linear gain stage used by per-app mixer faders and the mic chain.
///
/// Gain changes ramp over a few milliseconds so moving a slider or muting never
/// produces a click. The stage is allocation free in `process`.
public final class GainStage {
    private let sampleRate: Double
    private var currentGain: Float
    private var targetGain: Float
    private var smoothing: Float

    /// Creates a gain stage at unity gain.
    /// - Parameter rampMilliseconds: Time constant of the gain ramp.
    public init(sampleRate: Double, rampMilliseconds: Double = 20) {
        precondition(sampleRate > 0, "sample rate must be positive")
        precondition(rampMilliseconds > 0, "ramp must be positive")
        self.sampleRate = sampleRate
        currentGain = 1
        targetGain = 1
        smoothing = AudioMath.smoothingCoefficient(
            milliseconds: rampMilliseconds,
            sampleRate: sampleRate
        )
    }

    /// Current (possibly still ramping) linear gain.
    public var gain: Float { currentGain }

    /// True while the ramp has not reached its target.
    public var isRamping: Bool { abs(targetGain - currentGain) > 1e-5 }

    /// Sets the target linear gain. Values above 4 are clamped: ClearMix never
    /// boosts more than +12 dB, and the limiter protects the output.
    public func setGain(_ linear: Float) {
        targetGain = min(max(linear, 0), 4)
    }

    public func setGain(decibels: Float) {
        setGain(decibels <= -96 ? 0 : AudioMath.dbToLinear(decibels))
    }

    /// Immediately jumps to the target without a ramp (device setup, reset).
    public func snapToTarget() {
        currentGain = targetGain
    }

    public func updateRamp(milliseconds: Double) {
        smoothing = AudioMath.smoothingCoefficient(
            milliseconds: milliseconds,
            sampleRate: sampleRate
        )
    }

    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }

        if !isRamping {
            var value = currentGain
            vDSP_vsmul(samples, 1, &value, samples, 1, vDSP_Length(frames))
            return
        }

        let coefficient = smoothing
        var gain = currentGain
        let target = targetGain
        for index in 0..<frames {
            gain = target + (gain - target) * coefficient
            samples[index] *= gain
        }
        // An exponential ramp approaches its target without ever reaching it.
        // Snap the last inaudible step (-80 dB) so the stage stops ramping and
        // can take its cheaper unramped path.
        if abs(target - gain) < 1e-4 {
            gain = target
        }
        currentGain = gain
    }
}
