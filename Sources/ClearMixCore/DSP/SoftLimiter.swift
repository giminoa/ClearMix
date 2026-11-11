import Foundation

/// Feed-forward peak limiter with a hard ceiling guard.
///
/// Used for the +200...+400% boost feature and as the last stage of the mic
/// chain. Gain reduction is smooth (attack/release), and a final clamp at the
/// ceiling guarantees no sample ever exceeds it. There is no lookahead in this
/// version, so the clamp catches the very first sample of a sudden transient.
public final class SoftLimiter {
    private let sampleRate: Double
    private let attackCoefficient: Float
    private let releaseCoefficient: Float

    private var currentGain: Float = 1
    private var ceiling: Float

    /// Output ceiling in dBFS. -1 dB leaves headroom for lossy encoders.
    public var ceilingDB: Float = -1 {
        didSet { ceiling = AudioMath.dbToLinear(ceilingDB) }
    }

    public init(
        sampleRate: Double,
        ceilingDB: Float = -1,
        attackMilliseconds: Double = 1,
        releaseMilliseconds: Double = 120
    ) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.sampleRate = sampleRate
        self.ceilingDB = ceilingDB
        ceiling = AudioMath.dbToLinear(ceilingDB)
        attackCoefficient = AudioMath.smoothingCoefficient(
            milliseconds: attackMilliseconds,
            sampleRate: sampleRate
        )
        releaseCoefficient = AudioMath.smoothingCoefficient(
            milliseconds: releaseMilliseconds,
            sampleRate: sampleRate
        )
    }

    /// Current gain reduction as a linear multiplier (1 = no reduction).
    public var gain: Float { currentGain }

    public func reset() {
        currentGain = 1
    }

    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }

        let limit = ceiling
        var gain = currentGain
        let attack = attackCoefficient
        let release = releaseCoefficient

        for index in 0..<frames {
            let sample = samples[index]
            let peak = abs(sample)

            var target: Float = 1
            if peak > limit && peak > 1e-6 {
                target = limit / peak
            }

            let coefficient = target < gain ? attack : release
            gain = target + (gain - target) * coefficient

            var output = sample * gain
            if output > limit { output = limit } else if output < -limit { output = -limit }
            samples[index] = output
        }

        currentGain = gain
    }
}
