import Foundation

/// Small helpers shared by the audio stages.
public enum AudioMath {
    /// Linear amplitude from decibels relative to full scale.
    @inline(__always)
    public static func dbToLinear(_ decibels: Float) -> Float {
        powf(10, decibels / 20)
    }

    /// Decibels relative to full scale from a linear amplitude.
    @inline(__always)
    public static func linearToDb(_ linear: Float) -> Float {
        20 * log10f(max(linear, 1e-9))
    }

    /// One-pole smoothing coefficient for a time constant in milliseconds.
    @inline(__always)
    public static func smoothingCoefficient(milliseconds: Double, sampleRate: Double) -> Float {
        guard milliseconds > 0, sampleRate > 0 else { return 0 }
        return Float(exp(-1.0 / (milliseconds * 0.001 * sampleRate)))
    }

    /// Converts decibels per second into a per-frame multiplier.
    @inline(__always)
    public static func decayFactor(decibelsPerSecond: Double, frames: Int, sampleRate: Double) -> Float {
        guard frames > 0, sampleRate > 0 else { return 1 }
        let seconds = Double(frames) / sampleRate
        return Float(pow(10.0, -decibelsPerSecond * seconds / 20.0))
    }
}
