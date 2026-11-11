import Foundation

/// Keeps the capture ring near its target fill by trimming the resampling step
/// by a few thousandths of a percent.
///
/// Two audio devices never run on exactly the same clock. Even a 50 ppm mismatch
/// is 180 frames per minute: over a call the capture ring would either fill up
/// and start dropping frames or run dry and produce gaps. Rather than dropping
/// or inserting whole blocks (audible clicks), the chain resamples the stream by
/// `1 + correction`, where the correction is driven by the level error.
///
/// The plant is an integrator (fill changes at the rate the consumer runs faster
/// than the producer), so a proportional law with a time constant of a few
/// seconds settles without overshoot. The correction is clamped to a fraction of
/// a percent, far below anything a listener can hear.
public struct DriftController {
    /// Seconds over which a level error is turned into a rate correction.
    public var timeConstantSeconds = 4.0
    /// Largest allowed rate change (0.01 = 1 % = about 17 cents). Level error
    /// beyond the deadband decays with a 4 s time constant, so the clamp only
    /// matters right after a glitch overflowed or starved the ring; it is what
    /// lets 100 ms of excess fill be worked off in a few seconds.
    public var maxCorrection = 0.01
    /// Below this level error the correction is left alone, to keep the pitch
    /// perfectly steady once the loop has settled.
    public var deadbandSeconds = 0.003
    /// Seconds for a new correction to be reached, so the pitch never jumps.
    public var smoothingSeconds = 0.5

    /// Current rate offset; `step` is what the resampler should use.
    public private(set) var correction = 0.0

    public init() {}

    public var step: Double {
        1 + correction
    }

    /// Feeds one control step.
    ///
    /// - Parameters:
    ///   - errorSeconds: Fill minus target, expressed in seconds of audio.
    ///     Positive means the producer is running ahead of the consumer.
    ///   - elapsedSeconds: Audio time covered by the frames just processed.
    /// - Returns: the resampling step to use for the next block.
    @discardableResult
    public mutating func update(errorSeconds: Double, elapsedSeconds: Double) -> Double {
        guard elapsedSeconds > 0 else { return step }

        var desired = 0.0
        if abs(errorSeconds) > deadbandSeconds {
            desired = errorSeconds / timeConstantSeconds
            desired = min(max(desired, -maxCorrection), maxCorrection)
        }

        let alpha = min(1, elapsedSeconds / max(smoothingSeconds, 1e-6))
        correction += (desired - correction) * alpha
        return step
    }

    public mutating func reset() {
        correction = 0
    }
}
