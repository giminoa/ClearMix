import CMixRT

/// Lock-free single-producer / single-consumer ring buffer of interleaved
/// 32-bit float frames.
///
/// One audio thread writes while one consumer reads; no locks are taken and no
/// allocation happens after `init`. The type is safe to hand to exactly one
/// producer and one consumer thread, which is why it is `@unchecked Sendable`.
public final class AudioRingBuffer: @unchecked Sendable {
    private let ring: OpaquePointer

    public let capacity: Int
    public let channels: Int

    public init(capacityFrames: Int, channels: Int) {
        precondition(capacityFrames > 0, "capacity must be positive")
        precondition(channels > 0, "channels must be positive")
        guard let ring = cmix_ring_create(capacityFrames, UInt32(channels)) else {
            fatalError("AudioRingBuffer: allocation failed")
        }
        self.ring = ring
        self.channels = Int(cmix_ring_channels(ring))
        self.capacity = Int(cmix_ring_capacity(ring))
    }

    deinit {
        cmix_ring_destroy(ring)
    }

    /// Frames the consumer can read right now.
    public var availableToRead: Int {
        Int(cmix_ring_available_read(ring))
    }

    /// Frames the producer can write right now.
    public var availableToWrite: Int {
        Int(cmix_ring_available_write(ring))
    }

    public var isEmpty: Bool { availableToRead == 0 }

    /// Writes up to `frames` interleaved frames; returns how many were written.
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        return Int(cmix_ring_write(ring, src, frames))
    }

    /// Reads up to `frames` interleaved frames; returns how many were read.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        return Int(cmix_ring_read(ring, dst, frames))
    }

    /// Copies an array into the ring (test and offline-tool convenience).
    @discardableResult
    public func write(_ frames: [Float]) -> Int {
        frames.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return write(base, frames: frames.count / channels)
        }
    }

    public func read(frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * channels)
        let readCount = output.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return read(into: base, frames: frames)
        }
        if readCount < frames {
            output.removeLast((frames - readCount) * channels)
        }
        return output
    }

    /// Zero-copy producer access. Returns a contiguous writable block.
    public func writableBlock() -> UnsafeMutableBufferPointer<Float> {
        var frames: size_t = 0
        guard let pointer = cmix_ring_write_ptr(ring, &frames), frames > 0 else {
            return UnsafeMutableBufferPointer(start: nil, count: 0)
        }
        return UnsafeMutableBufferPointer(start: pointer, count: Int(frames) * channels)
    }

    public func advanceWrite(frames: Int) {
        guard frames > 0 else { return }
        cmix_ring_advance_write(ring, frames)
    }

    /// Zero-copy consumer access. Returns a contiguous readable block.
    public func readableBlock() -> UnsafeBufferPointer<Float> {
        var frames: size_t = 0
        guard let pointer = cmix_ring_read_ptr(ring, &frames), frames > 0 else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: pointer, count: Int(frames) * channels)
    }

    public func advanceRead(frames: Int) {
        guard frames > 0 else { return }
        cmix_ring_advance_read(ring, frames)
    }

    /// Drops all buffered frames. Only call while no other thread uses the ring.
    public func removeAll() {
        cmix_ring_clear(ring)
    }
}
