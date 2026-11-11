import Accelerate
import Foundation

/// Fractional-delay sample rate converter built on a windowed-sinc kernel.
///
/// The converter is allocation free after `init`, so it can run on a realtime
/// audio thread. It also accepts a small drift offset, which the microphone
/// engine uses to keep the input device and BlackHole from slowly desyncing.
///
/// Output sample `n` sits at input position `n * (inRate/outRate)` measured in
/// input frames. The converter needs `latencyFrames` input frames of lookahead
/// before it can emit that sample, which is its contribution to chain latency.
public final class SampleRateConverter {
    public let inputRate: Double
    public let outputRate: Double
    public let taps: Int
    public let phases: Int

    private let halfTaps: Int
    private let kernel: UnsafeMutablePointer<Float>
    private let accumulator: UnsafeMutablePointer<Float>
    private let accumulatorCapacity: Int
    private var accumulatorCount: Int
    /// Absolute read position in input frames, never rebased: keeping the
    /// running sum untouched makes the output independent of how the input is
    /// split into calls, so block and single-call processing agree exactly.
    private var position: Double
    /// Input frames already dropped from the front of the accumulator.
    private var droppedFrames: Int
    private var step: Double
    private let baseStep: Double
    private let cutoff: Double

    /// - Parameters:
    ///   - taps: Filter length; must be even and at least 8.
    ///   - phases: Number of precomputed fractional phases.
    ///   - maxFramesPerCall: Internal buffer size. A single call may process at
    ///     most this many frames; larger calls are split internally.
    public init(
        inputRate: Double,
        outputRate: Double,
        taps: Int = 32,
        phases: Int = 1024,
        maxFramesPerCall: Int = 8192
    ) {
        precondition(inputRate > 0 && outputRate > 0, "sample rates must be positive")
        precondition(taps >= 8 && taps.isMultiple(of: 2), "taps must be even and >= 8")
        precondition(phases >= 64, "phases must be >= 64")
        precondition(maxFramesPerCall > taps * 2, "buffer must hold a kernel of history")

        self.inputRate = inputRate
        self.outputRate = outputRate
        self.taps = taps
        self.phases = phases
        halfTaps = taps / 2
        baseStep = inputRate / outputRate
        step = baseStep
        // Upsampling can keep the full input band; downsampling must band-limit
        // first or content above the new Nyquist folds back as aliasing.
        cutoff = outputRate >= inputRate ? 1.0 : 0.95 * outputRate / inputRate

        accumulatorCapacity = maxFramesPerCall + taps * 2
        accumulator = UnsafeMutablePointer<Float>.allocate(capacity: accumulatorCapacity)
        accumulator.initialize(repeating: 0, count: accumulatorCapacity)
        // Prime the accumulator with half a kernel of silence so the first
        // output can interpolate input frame 0 while still reading the kernel's
        // trailing edge; those frames are history, not dropped input.
        accumulatorCount = halfTaps
        droppedFrames = 0
        position = Double(halfTaps)

        kernel = UnsafeMutablePointer<Float>.allocate(capacity: phases * taps)
        Self.buildKernel(
            into: kernel,
            taps: taps,
            phases: phases,
            cutoff: Float(cutoff)
        )
    }

    deinit {
        kernel.deallocate()
        accumulator.deallocate()
    }

    /// Input frames of lookahead the converter needs before emitting output.
    /// The stream is delayed by this much, but output stays aligned to the input
    /// timeline (output frame 0 is input position 0).
    public var latencyFrames: Int {
        Int((Double(halfTaps) / step).rounded())
    }

    /// Input frames to feed `process` so it can emit `outputFrames` frames.
    /// Includes one kernel of margin for the lookahead.
    public func inputFrames(forOutputFrames outputFrames: Int) -> Int {
        Int((Double(outputFrames) * step).rounded(.up)) + taps
    }

    /// Adjusts the conversion ratio by parts per million for clock drift.
    /// Positive values make the converter consume slightly more input per output.
    public func setDriftPPM(_ ppm: Double) {
        step = baseStep * (1.0 + ppm / 1_000_000.0)
    }

    public func reset() {
        accumulator.update(repeating: 0, count: accumulatorCount)
        accumulatorCount = halfTaps
        droppedFrames = 0
        position = Double(halfTaps)
        step = baseStep
    }

    /// Converts `inputFrames` frames into `output`.
    ///
    /// `output` must have room for at least `ceil(inputFrames / step) + 1`
    /// frames. Returns the number of frames produced, or -1 if the output
    /// buffer was too small to consume all input.
    public func process(
        input: UnsafePointer<Float>,
        inputFrames: Int,
        output: UnsafeMutablePointer<Float>,
        maxOutputFrames: Int
    ) -> Int {
        guard inputFrames > 0 else { return 0 }

        var consumed = 0
        var produced = 0
        let phaseScale = Double(phases)

        while consumed < inputFrames {
            let room = accumulatorCapacity - accumulatorCount
            if room <= 0 { break }
            let take = min(room, inputFrames - consumed)
            (accumulator + accumulatorCount).update(from: input + consumed, count: take)
            accumulatorCount += take
            consumed += take

            let limit = Double(droppedFrames + accumulatorCount - halfTaps)
            while position <= limit && produced < maxOutputFrames {
                let absolute = Int(position)
                let base = absolute - droppedFrames
                var phase = Int((position - Double(absolute)) * phaseScale + 0.5)
                if phase >= phases { phase = phases - 1 }

                var sample: Float = 0
                vDSP_dotpr(
                    kernel + phase * taps, 1,
                    accumulator + (base - halfTaps), 1,
                    &sample,
                    vDSP_Length(taps)
                )
                output[produced] = sample
                produced += 1
                position += step
            }

            compact()
            if produced >= maxOutputFrames && consumed < inputFrames {
                return -1
            }
        }

        return produced
    }

    /// Convenience wrapper for tests and offline tools. Allocates.
    public func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        let capacity = Int(ceil(Double(input.count) / step)) + taps + 2
        var output = [Float](repeating: 0, count: capacity)
        let produced = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                process(
                    input: source.baseAddress!,
                    inputFrames: input.count,
                    output: destination.baseAddress!,
                    maxOutputFrames: capacity
                )
            }
        }
        if produced < 0 { return [] }
        return Array(output.prefix(produced))
    }

    // MARK: - Private

    /// Drops the history no future output needs. `position` stays absolute; only
    /// `droppedFrames` moves, which keeps the position sequence reproducible.
    private func compact() {
        let keepFrom = Int(position) - droppedFrames - halfTaps
        guard keepFrom > 0 else { return }
        let remaining = accumulatorCount - keepFrom
        if remaining > 0 {
            memmove(
                accumulator,
                accumulator + keepFrom,
                remaining * MemoryLayout<Float>.stride
            )
        }
        accumulatorCount = max(remaining, 0)
        droppedFrames += keepFrom
    }

    private static func buildKernel(
        into kernel: UnsafeMutablePointer<Float>,
        taps: Int,
        phases: Int,
        cutoff: Float
    ) {
        let half = Double(taps / 2)
        let cutoffD = Double(cutoff)

        for phase in 0..<phases {
            let fraction = Double(phase) / Double(phases)
            var sum = 0.0

            for tap in 0..<taps {
                let distance = Double(tap) - half - fraction
                let scaled = cutoffD * distance

                let sinc: Double
                if abs(scaled) < 1e-9 {
                    sinc = 1
                } else {
                    let angle = Double.pi * scaled
                    sinc = sin(angle) / angle
                }

                // Blackman window over the kernel span.
                var window = 0.0
                if abs(distance) <= half {
                    let arg = Double.pi * distance / half
                    window = 0.42 + 0.5 * cos(arg) + 0.08 * cos(2 * arg)
                }

                let value = cutoffD * sinc * window
                kernel[phase * taps + tap] = Float(value)
                sum += value
            }

            // Normalize each phase so DC gain is exactly unity.
            if abs(sum) > 1e-9 {
                let scale = Float(1.0 / sum)
                for tap in 0..<taps {
                    kernel[phase * taps + tap] *= scale
                }
            }
        }
    }
}
