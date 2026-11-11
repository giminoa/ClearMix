import Foundation

/// Fractional-rate resampler with linear interpolation.
///
/// Used to correct the slow clock drift between two audio devices: running it at
/// `step = 1.000002` consumes two millionths more input frames than it emits, so
/// a capture stream that arrives slightly fast is gently pulled back to the
/// buffer level we want without ever dropping or repeating a whole block.
///
/// `process` is realtime safe: it only touches its own scalar state and the
/// caller's buffers. Linear interpolation at the drift ratios involved
/// (≤ 0.2 %) stays far below the noise floor of a microphone.
public struct LinearResampler {
    /// Interpolation position inside the current segment, in `0..<1`.
    public private(set) var fraction: Double = 0
    /// Whether `pending` holds a sample carried over from the previous call.
    public private(set) var hasPending = false
    private var pending: Float = 0

    public init() {}

    /// Upper bound on the frames `process` can emit for `frames` input frames.
    public static func maxOutputFrames(inputFrames: Int, step: Double) -> Int {
        Int(Double(inputFrames) / max(step, 0.5)) + 4
    }

    public mutating func reset() {
        fraction = 0
        hasPending = false
        pending = 0
    }

    /// Resamples `frames` input frames into `output`.
    ///
    /// - Parameter step: input frames consumed per output frame. `1` is a
    ///   pass-through (one frame of delay), `> 1` consumes faster, `< 1` slower.
    /// - Returns: frames written; at most `LinearResampler.maxOutputFrames`.
    @discardableResult
    public mutating func process(
        _ input: UnsafePointer<Float>,
        frames: Int,
        step: Double,
        output: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> Int {
        guard frames > 0, capacity > 0 else { return 0 }
        let step = max(step, 0.5)

        var a: Float
        var index: Int
        if hasPending {
            // `pending` is the last sample of the previous block, so this
            // block starts immediately after it.
            a = pending
            index = 0
            hasPending = false
        } else {
            // Nothing carried over: seed the segment with the first frame.
            a = input[0]
            index = 1
        }

        var position = fraction
        var written = 0

        while index < frames {
            let b = input[index]
            while position < 1, written < capacity {
                output[written] = a + (b - a) * Float(position)
                written += 1
                position += step
            }
            // Out of room mid-segment: keep the state and resume next call.
            guard position >= 1 else { break }
            position -= 1
            a = b
            index += 1
        }

        pending = a
        hasPending = true
        fraction = position
        return written
    }
}
