import CMixRNNoise
import Foundation

/// Noise suppression stage backed by RNNoise.
///
/// RNNoise is a recurrent model that only accepts 48 kHz mono blocks of 10 ms,
/// so this stage is the clock of the mic chain: capture has to deliver exactly
/// `frameSize` samples per call. The instance owns its recurrent state and a
/// preallocated scratch buffer inside the C shim, which makes `process`
/// allocation-free and safe to call from a realtime thread.
public final class Denoiser: @unchecked Sendable {
    /// Samples per block: 10 ms at 48 kHz.
    public static let frameSize = 480
    /// The only sample rate RNNoise supports.
    public static let sampleRate: Double = 48_000

    /// Block size reported by the shim, checked against `frameSize` at init.
    public let blockSize: Int
    public let sampleRate: Double

    /// RNNoise's voice-activity probability for the most recent block (0...1).
    public private(set) var voiceProbability: Float = 0

    private let handle: OpaquePointer

    /// Creates a denoiser, or returns nil if RNNoise could not be initialised.
    public init?() {
        guard let handle = cmix_denoiser_create() else { return nil }
        let size = Int(cmix_denoiser_frame_size(handle))
        let rate = Double(cmix_denoiser_sample_rate(handle))
        guard size == Denoiser.frameSize, rate == Denoiser.sampleRate else {
            cmix_denoiser_destroy(handle)
            return nil
        }
        self.handle = handle
        self.blockSize = size
        self.sampleRate = rate
    }

    deinit {
        cmix_denoiser_destroy(handle)
    }

    /// Denoises one block in place and returns the voice-activity probability.
    ///
    /// - Parameter frame: exactly `frameSize` interleaved-free mono samples in
    ///   the -1...1 range. No bounds checking happens here by design; the
    ///   caller owns the buffer and its length.
    @discardableResult
    @inline(__always)
    public func process(_ frame: UnsafeMutablePointer<Float>) -> Float {
        let voice = cmix_denoiser_process(handle, frame)
        voiceProbability = voice
        return voice
    }

    /// Denoises as many whole blocks as fit and returns how many frames it
    /// consumed. The remainder is left untouched so the caller can carry it
    /// into the next call.
    @discardableResult
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames >= blockSize else { return 0 }
        var offset = 0
        while frames - offset >= blockSize {
            process(samples + offset)
            offset += blockSize
        }
        return offset
    }
}
