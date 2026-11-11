import CMixRT
import Foundation

/// Thread-safe counters that a realtime callback can update and the UI can read.
///
/// The storage lives in C so the audio thread only touches atomics: no locks, no
/// allocation, no Swift runtime traffic beyond a single function call.
public final class RealtimeStats: @unchecked Sendable {
    /// Frame counts read from the audio thread, copied consistently enough for
    /// diagnostics (each field is atomic, the set is not transactional).
    public struct Snapshot: Sendable, Equatable {
        public var underrunFrames: UInt64
        public var overrunFrames: UInt64
        public var framesIn: UInt64
        public var framesOut: UInt64
        /// Frames waiting in the capture ring; negative would mean empty.
        public var fillFrames: Int64
    }

    private let storage: OpaquePointer

    public init() {
        guard let storage = cmix_stats_create() else {
            fatalError("RealtimeStats: allocation failed")
        }
        self.storage = storage
    }

    deinit {
        cmix_stats_destroy(storage)
    }

    public var snapshot: Snapshot {
        let raw = cmix_stats_read(storage)
        return Snapshot(
            underrunFrames: raw.underrun_frames,
            overrunFrames: raw.overrun_frames,
            framesIn: raw.frames_in,
            framesOut: raw.frames_out,
            fillFrames: raw.fill_frames
        )
    }

    @inline(__always)
    public func recordUnderrun(frames: Int) {
        cmix_stats_add_underrun(storage, UInt64(frames))
    }

    @inline(__always)
    public func recordOverrun(frames: Int) {
        cmix_stats_add_overrun(storage, UInt64(frames))
    }

    @inline(__always)
    public func recordFrames(input: Int, output: Int) {
        cmix_stats_add_frames(storage, UInt64(input), UInt64(output))
    }

    @inline(__always)
    public func setFill(frames: Int) {
        cmix_stats_set_fill(storage, Int64(frames))
    }

    public func reset() {
        cmix_stats_reset(storage)
    }
}
