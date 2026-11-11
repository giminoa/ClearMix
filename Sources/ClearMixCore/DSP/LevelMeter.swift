import Accelerate
import Foundation

/// Peak and RMS meter with display ballistics.
///
/// The UI draws one of these per app row in the mixer and one for the mic.
/// Meters are only fed while the popover is visible.
public final class LevelMeter {
    private let sampleRate: Double
    private let decayDBPerSecond: Double

    private var peakLinear: Float = 0
    private var rmsLinear: Float = 0

    public init(sampleRate: Double, decayDBPerSecond: Double = 20) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.sampleRate = sampleRate
        self.decayDBPerSecond = decayDBPerSecond
    }

    /// Smoothed peak amplitude, 0...1+.
    public var peak: Float { peakLinear }
    /// Smoothed RMS amplitude, 0...1+.
    public var rms: Float { rmsLinear }

    public var peakDB: Float { AudioMath.linearToDb(peakLinear) }
    public var rmsDB: Float { AudioMath.linearToDb(rmsLinear) }

    public func reset() {
        peakLinear = 0
        rmsLinear = 0
    }

    public func process(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }

        var blockPeak: Float = 0
        vDSP_maxmgv(samples, 1, &blockPeak, vDSP_Length(frames))

        var blockRMS: Float = 0
        vDSP_rmsqv(samples, 1, &blockRMS, vDSP_Length(frames))

        let decay = AudioMath.decayFactor(
            decibelsPerSecond: decayDBPerSecond,
            frames: frames,
            sampleRate: sampleRate
        )
        peakLinear = max(blockPeak, peakLinear * decay)
        rmsLinear = max(blockRMS, rmsLinear * decay)
    }
}
