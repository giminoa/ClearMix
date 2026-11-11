import XCTest
@testable import ClearMixCore

/// Replays the engine's two-thread loop without any audio device: a simulated
/// capture thread writes 256-frame slices into the ring, and the render side
/// runs exactly the loop `MicEngine.render` runs.
final class MicEngineLoopTests: XCTestCase {
    private let rate = 48_000
    private let blockOut = 256
    private let renderInterval = 256.0 / 48_000

    private struct Result {
        var consumed = 0
        var produced = 0
        var maxFill = 0
        var minFill = Int.max
        var dropped = 0
        var overflow = 0
        var step = 1.0
    }

    private func simulate(
        seconds: Double,
        producerPPM: Double = 0,
        targetMilliseconds: Int = 20
    ) -> Result {
        let chain = MicChain(inputSampleRate: 48_000, channels: 1, maxInputFrames: 4_096)!
        chain.gate.isEnabled = false
        chain.gain.setGain(decibels: -6)
        chain.targetFillFrames = targetMilliseconds * rate / 1_000

        let ring = AudioRingBuffer(capacityFrames: 2_880, channels: 1)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4_096)
        scratch.initialize(repeating: 0.1, count: 4_096)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: blockOut)
        out.initialize(repeating: 0, count: blockOut)
        defer {
            scratch.deallocate()
            out.deallocate()
        }

        var result = Result()
        var captureBudget = 0.0 // fractional, models a producer clock offset
        var readCredit = 0.0
        var elapsed = 0.0
        let producerRate = 48_000 * (1 + producerPPM * 1e-6)

        for _ in 0..<Int(seconds / renderInterval) {
            elapsed += renderInterval

            captureBudget += Double(blockOut) * (producerRate / 48_000)
            while captureBudget >= 256 {
                let written = ring.write(scratch, frames: 256)
                if written < 256 { result.overflow += 256 - written }
                captureBudget -= 256
            }

            readCredit += Double(blockOut) * chain.driftStep
            let wanted = min(Int(readCredit), 4_096)
            let read = wanted > 0 ? ring.read(into: scratch, frames: wanted) : 0
            readCredit -= Double(read)
            if read > 0 {
                chain.setCaptureFill(ring.availableToRead)
                chain.process(scratch, frames: read)
                result.consumed += read
            }

            result.produced += chain.pull(into: out, maxFrames: blockOut)
            result.dropped = chain.droppedFrames

            if elapsed >= 10 { // ignore the cold-start fill-up
                let fill = ring.availableToRead
                result.maxFill = max(result.maxFill, fill)
                result.minFill = min(result.minFill, fill)
            }
        }

        result.step = chain.driftStep
        return result
    }

    func testRingStaysNearItsTarget() {
        let result = simulate(seconds: 60)
        XCTAssertEqual(result.overflow, 0, "capture ring overflowed")
        XCTAssertEqual(result.dropped, 0, "output FIFO dropped frames")
        XCTAssertLessThan(result.maxFill, 2_880, "ring grew past its capacity")
        XCTAssertGreaterThan(result.minFill, 0, "ring ran dry")
        XCTAssertEqual(result.produced, 48_000 * 60, accuracy: 2_000)
    }

    func testOutputRateMatchesTheDriftStep() {
        let result = simulate(seconds: 20)
        guard result.consumed > 0 else { return XCTFail("no audio") }
        let ratio = Double(result.produced) / Double(result.consumed)
        XCTAssertEqual(ratio, 1 / result.step, accuracy: 0.005)
    }

    func testFastProducerDoesNotOverflowTheRing() {
        // 300 ppm fast adds about 900 frames per minute: without correction the
        // ring would fill up within a few minutes of a call.
        let result = simulate(seconds: 90, producerPPM: 300)
        XCTAssertEqual(result.overflow, 0, "ring overflowed under clock drift")
        XCTAssertEqual(result.dropped, 0, "FIFO dropped frames under clock drift")
        // Level is held inside the controller's deadband plus one block.
        XCTAssertLessThan(result.maxFill, 960 + 400)
        XCTAssertGreaterThan(result.step, 1, "correction never engaged")
    }

    func testSlowProducerDoesNotStarveTheRing() {
        let result = simulate(seconds: 90, producerPPM: -300)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertGreaterThan(result.minFill, 960 - 400, "ring ran dry under clock drift")
        XCTAssertLessThan(result.step, 1, "correction never engaged")
    }
}
