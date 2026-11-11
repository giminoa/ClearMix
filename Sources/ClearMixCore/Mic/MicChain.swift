import Accelerate
import Foundation

/// Device-free microphone processing chain: downmix → 48 kHz → RNNoise → gate →
/// gain → limiter.
///
/// The chain is the clock of the mic path. RNNoise only accepts 480-sample
/// blocks, so input is resampled to 48 kHz and collected into whole blocks; a
/// partial tail waits for the next call. Processed frames land in a small FIFO
/// that the caller drains at whatever block size the output device asks for.
///
/// Every buffer is allocated in `init`. `process` and `pull` are realtime safe:
/// no allocation, no locks, no Swift collections.
public final class MicChain: @unchecked Sendable {
    /// RNNoise's working rate; the whole chain runs here.
    public static let sampleRate: Double = 48_000
    /// Frames per RNNoise block (10 ms).
    public static let blockSize = Denoiser.frameSize

    public let inputSampleRate: Double
    public let inputChannels: Int

    public let denoiser: Denoiser
    public let gate: NoiseGate
    public let gain: GainStage
    public let limiter: SoftLimiter

    /// Largest `frames` value a single `process` call may pass.
    public let maxInputFrames: Int

    /// Skip RNNoise while keeping the rest of the chain in place.
    public var denoiseEnabled = true
    /// Wet/dry mix for RNNoise (0 = raw, 1 = full RNNoise). Clamped to 0...1.
    public var denoiseStrength: Float = 1.0
    /// Instant A/B bypass: passes raw audio (with gain/limiter) without denoise or gate.
    public var abBypass = false

    /// Capture ring level the engine should hold, in input frames. Zero disables
    /// drift correction: `setCaptureFill` then has nothing to steer towards.
    public var targetFillFrames = 0
    /// Rate correction currently applied to the stream (1.0 = no change).
    public private(set) var driftStep = 1.0

    /// RNNoise voice-activity probability of the last block (0...1).
    public private(set) var voiceProbability: Float = 0
    /// Peak of the most recent input block, before any processing.
    public private(set) var inputPeak: Float = 0
    /// Peak of the most recent processed block, after the limiter.
    public private(set) var outputPeak: Float = 0
    /// Frames the output FIFO had to drop because the consumer stalled.
    public private(set) var droppedFrames = 0

    private let converter: SampleRateConverter
    private let mono: UnsafeMutablePointer<Float>
    private let converted: UnsafeMutablePointer<Float>
    private let convertedCapacity: Int
    private var resampler = LinearResampler()
    private var drift = DriftController()
    /// Last capture-ring level the engine reported, in input frames.
    public private(set) var captureFill = 0
    private let assembled: UnsafeMutablePointer<Float>
    private let assembledCapacity: Int
    private var assembledCount = 0
    private let dryBlock: UnsafeMutablePointer<Float>

    /// Power-of-two FIFO for finished 48 kHz mono frames.
    private let pending: UnsafeMutablePointer<Float>
    private let pendingMask: Int
    private var pendingRead = 0
    private var pendingWrite = 0

    /// - Parameters:
    ///   - inputSampleRate: Rate of the captured stream.
    ///   - inputChannels: Interleaved channel count of the captured stream.
    ///   - maxInputFrames: Frames per `process` call; the engine sizes its
    ///     capture scratch from this.
    public init?(inputSampleRate: Double, channels inputChannels: Int, maxInputFrames: Int = 4_096) {
        precondition(inputSampleRate > 0, "input rate must be positive")
        precondition(inputChannels > 0, "at least one channel is required")
        precondition(maxInputFrames > 0, "maxInputFrames must be positive")

        guard let denoiser = Denoiser() else { return nil }

        self.inputSampleRate = inputSampleRate
        self.inputChannels = inputChannels
        self.denoiser = denoiser
        self.maxInputFrames = maxInputFrames

        gate = NoiseGate(sampleRate: Self.sampleRate)
        gate.isEnabled = false
        gain = GainStage(sampleRate: Self.sampleRate)
        limiter = SoftLimiter(sampleRate: Self.sampleRate)

        converter = SampleRateConverter(
            inputRate: inputSampleRate,
            outputRate: Self.sampleRate,
            maxFramesPerCall: maxInputFrames
        )

        let ratio = Self.sampleRate / inputSampleRate
        let convertedCapacity = Int((Double(maxInputFrames) * ratio).rounded(.up)) + 64
        // The drift stage runs slower than the converter by up to the controller's
        // clamp, so its output can be a percent longer than the converter's. If
        // the staging buffer were only `convertedCapacity` long, an over-long
        // block would be truncated mid-segment and the resampler state would
        // repeat frames on the next call.
        let slowestStep = 1 - DriftController().maxCorrection
        assembledCapacity = Int(Double(convertedCapacity) / slowestStep) + Self.blockSize + 8
        assembled = .allocate(capacity: assembledCapacity)
        assembled.initialize(repeating: 0, count: assembledCapacity)

        mono = .allocate(capacity: maxInputFrames)
        mono.initialize(repeating: 0, count: maxInputFrames)

        self.convertedCapacity = convertedCapacity
        converted = .allocate(capacity: convertedCapacity)
        converted.initialize(repeating: 0, count: convertedCapacity)

        let fifoCapacity = 8_192
        pending = .allocate(capacity: fifoCapacity)
        pending.initialize(repeating: 0, count: fifoCapacity)
        pendingMask = fifoCapacity - 1

        dryBlock = .allocate(capacity: Self.blockSize)
        dryBlock.initialize(repeating: 0, count: Self.blockSize)
    }

    deinit {
        assembled.deallocate()
        converted.deallocate()
        mono.deallocate()
        pending.deallocate()
        dryBlock.deallocate()
    }

    /// Tells the chain how much audio is waiting in the capture ring, so the
    /// drift controller can steer it back to `targetFillFrames`. Realtime safe.
    public func setCaptureFill(_ frames: Int) {
        captureFill = frames
    }

    /// Frames of processed audio waiting to be pulled.
    public var pendingCount: Int {
        (pendingWrite - pendingRead) & pendingMask
    }

    /// Latency the chain itself adds, in output frames: the resampler's lookahead
    /// plus the block RNNoise has to fill before it can run.
    public var latencyFrames: Int {
        converter.latencyFrames + Self.blockSize
    }

    /// Pushes interleaved input frames through the chain.
    ///
    /// - Returns: processed frames appended to the output FIFO.
    @discardableResult
    public func process(_ input: UnsafePointer<Float>, frames: Int) -> Int {
        guard frames > 0, frames <= maxInputFrames else { return 0 }

        downmix(input, frames: frames)

        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(frames))
        inputPeak = peak

        let converted = converter.process(
            input: mono,
            inputFrames: frames,
            output: self.converted,
            maxOutputFrames: convertedCapacity
        )
        guard converted > 0 else { return 0 }

        let room = assembledCapacity - assembledCount
        let produced: Int
        if targetFillFrames > 0 {
            let errorSeconds = Double(captureFill - targetFillFrames) / inputSampleRate
            let elapsed = Double(converted) / Self.sampleRate
            driftStep = drift.update(errorSeconds: errorSeconds, elapsedSeconds: elapsed)
            produced = resampler.process(
                self.converted,
                frames: converted,
                step: driftStep,
                output: assembled + assembledCount,
                capacity: room
            )
        } else {
            produced = min(converted, room)
            assembled.advanced(by: assembledCount).update(from: self.converted, count: produced)
        }
        guard produced > 0 else { return 0 }
        assembledCount += produced

        var offset = 0
        var blockPeak: Float = 0
        while assembledCount - offset >= Self.blockSize {
            let block = assembled + offset
            if !abBypass && denoiseEnabled {
                let wet = min(max(denoiseStrength, 0), 1)
                if wet > 0 {
                    if wet < 0.999 {
                        dryBlock.update(from: block, count: Self.blockSize)
                        voiceProbability = denoiser.process(block)
                        let dry = 1 - wet
                        for i in 0..<Self.blockSize {
                            block[i] = block[i] * wet + dryBlock[i] * dry
                        }
                    } else {
                        voiceProbability = denoiser.process(block)
                    }
                }
            }
            if !abBypass {
                gate.process(block, frames: Self.blockSize)
            }
            gain.process(block, frames: Self.blockSize)
            limiter.process(block, frames: Self.blockSize)

            var peak: Float = 0
            vDSP_maxmgv(block, 1, &peak, vDSP_Length(Self.blockSize))
            blockPeak = max(blockPeak, peak)

            append(block, frames: Self.blockSize)
            offset += Self.blockSize
        }
        if blockPeak > 0 {
            outputPeak = blockPeak
        }

        if offset > 0 {
            let remainder = assembledCount - offset
            if remainder > 0 {
                memmove(assembled, assembled + offset, remainder * MemoryLayout<Float>.stride)
            }
            assembledCount = remainder
        }

        return produced
    }

    /// Copies up to `maxFrames` processed frames out, in order.
    @discardableResult
    public func pull(into output: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let available = min(pendingCount, maxFrames)
        guard available > 0 else { return 0 }
        for index in 0..<available {
            output[index] = pending[(pendingRead + index) & pendingMask]
        }
        pendingRead = (pendingRead + available) & pendingMask
        return available
    }

    /// Offline convenience: runs a whole signal through the chain.
    public func processOffline(_ input: [Float], chunkFrames: Int = 1_024) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(input.count)
        let totalFrames = input.count / inputChannels
        var offset = 0
        var scratch = [Float](repeating: 0, count: pendingMask + 1)
        while offset < totalFrames {
            let frames = min(chunkFrames, totalFrames - offset)
            input.withUnsafeBufferPointer { source in
                _ = process(source.baseAddress! + offset * inputChannels, frames: frames)
            }
            scratch.withUnsafeMutableBufferPointer { destination in
                let pulled = pull(into: destination.baseAddress!, maxFrames: destination.count)
                output.append(contentsOf: UnsafeBufferPointer(start: destination.baseAddress, count: pulled))
            }
            offset += frames
        }
        return output
    }

    public func reset() {
        converter.reset()
        resampler.reset()
        drift.reset()
        driftStep = 1
        captureFill = 0
        gate.reset()
        limiter.reset()
        assembledCount = 0
        pendingRead = 0
        pendingWrite = 0
        voiceProbability = 0
    }

    // MARK: - Internals

    @inline(__always)
    private func downmix(_ input: UnsafePointer<Float>, frames: Int) {
        if inputChannels == 1 {
            mono.update(from: input, count: frames)
            return
        }
        let scale = 1 / Float(inputChannels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * inputChannels
            for channel in 0..<inputChannels {
                sum += input[base + channel]
            }
            mono[frame] = sum * scale
        }
    }

    @inline(__always)
    private func append(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let used = (pendingWrite - pendingRead) & pendingMask
        let free = pendingMask - used
        let count = min(frames, free)
        if count < frames {
            droppedFrames += frames - count
        }
        for index in 0..<count {
            pending[(pendingWrite + index) & pendingMask] = samples[index]
        }
        pendingWrite = (pendingWrite + count) & pendingMask
    }
}
