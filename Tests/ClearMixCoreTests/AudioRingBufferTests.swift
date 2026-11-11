import XCTest
@testable import ClearMixCore

final class AudioRingBufferTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    func testCapacityRoundsUpToPowerOfTwo() {
        let buffer = AudioRingBuffer(capacityFrames: 300, channels: 2)
        XCTAssertEqual(buffer.capacity, 512)
        XCTAssertEqual(buffer.availableToWrite, 512)
        XCTAssertEqual(buffer.availableToRead, 0)
    }

    func testWriteReadRoundTripAcrossWrap() {
        let buffer = AudioRingBuffer(capacityFrames: 8, channels: 2)
        var input = (0..<16).map(Float.init)  // 8 frames, stereo

        XCTAssertEqual(buffer.write(input), 8)
        XCTAssertEqual(buffer.availableToRead, 8)
        XCTAssertEqual(buffer.availableToWrite, 0)

        // Drain, then write again so the storage wraps around.
        let first = buffer.read(frames: 8)
        XCTAssertEqual(first, input)

        input = (100..<116).map(Float.init)
        XCTAssertEqual(buffer.write(input), 8)
        XCTAssertEqual(buffer.read(frames: 8), input)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPartialWriteWhenFull() {
        let buffer = AudioRingBuffer(capacityFrames: 4, channels: 1)
        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        // capacity is rounded to 4
        XCTAssertEqual(buffer.write(samples), 4)
        XCTAssertEqual(buffer.read(frames: 4), [1, 2, 3, 4])
        XCTAssertEqual(buffer.write(samples), 4)
    }

    func testReadStopsAtAvailableFrames() {
        let buffer = AudioRingBuffer(capacityFrames: 8, channels: 1)
        XCTAssertEqual(buffer.write([1, 2, 3]), 3)
        XCTAssertEqual(buffer.read(frames: 10), [1, 2, 3])
    }

    func testZeroCopyBlocksAreContiguous() {
        let buffer = AudioRingBuffer(capacityFrames: 8, channels: 1)
        // Move the write head near the end so the block wraps.
        _ = buffer.write([Float](repeating: 0, count: 6))
        _ = buffer.read(frames: 6)

        // Zero-copy blocks stop at the wrap point: the write head sits at 6 of
        // 8 frames, so only the last two are contiguous.
        let block = buffer.writableBlock()
        XCTAssertEqual(block.count, 2)
        block[0] = 42
        buffer.advanceWrite(frames: 1)

        let readable = buffer.readableBlock()
        XCTAssertEqual(readable.count, 1)
        XCTAssertEqual(readable[0], 42)
        buffer.advanceRead(frames: 1)
    }

    /// One producer, one consumer: every frame must arrive once, in order.
    func testConcurrentProducerConsumer() {
        let total = 200_000
        let buffer = AudioRingBuffer(capacityFrames: 2048, channels: 1)
        let mismatch = Flag()
        let group = DispatchGroup()

        let producer = DispatchQueue(label: "clearmix.producer")
        let consumer = DispatchQueue(label: "clearmix.consumer")

        group.enter()
        producer.async {
            var written = 0
            while written < total {
                var value = Float(written)
                written += buffer.write(&value, frames: 1)
            }
            group.leave()
        }

        group.enter()
        consumer.async {
            var expected: Float = 0
            var spins = 0
            while expected < Float(total) {
                var value: Float = -1
                if buffer.read(into: &value, frames: 1) == 1 {
                    if value != expected { mismatch.value = true }
                    expected += 1
                } else {
                    spins += 1
                    if spins > 50_000_000 {
                        mismatch.value = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0)
                }
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertFalse(mismatch.value, "frames arrived out of order or were dropped")
        XCTAssertTrue(buffer.isEmpty)
    }
}
