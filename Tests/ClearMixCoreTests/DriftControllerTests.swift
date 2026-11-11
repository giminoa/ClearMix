import XCTest
@testable import ClearMixCore

final class DriftControllerTests: XCTestCase {
    /// One render callback of 512 frames at 48 kHz.
    private let blockOut = 512.0
    private let rate = 48_000.0

    func testCorrectionIsClamped() {
        var controller = DriftController()
        for _ in 0..<200 {
            controller.update(errorSeconds: 10, elapsedSeconds: 0.01)
        }
        XCTAssertLessThanOrEqual(controller.correction, controller.maxCorrection)
        // Smoothing approaches the clamp asymptotically.
        XCTAssertGreaterThan(controller.correction, controller.maxCorrection * 0.98)
    }

    func testNoCorrectionInsideDeadband() {
        var controller = DriftController()
        for _ in 0..<100 {
            controller.update(errorSeconds: 0.001, elapsedSeconds: 0.01)
        }
        XCTAssertEqual(controller.correction, 0, accuracy: 1e-12)
        XCTAssertEqual(controller.step, 1, accuracy: 1e-12)
    }

    func testFasterProducerIsPulledBackWithoutOvershoot() {
        // Producer runs 150 ppm fast: the ring would gain ~7 frames per second
        // and overflow within a minute without correction.
        let drift = 150e-6
        let target = 960.0
        var fill = 9_600.0
        var controller = DriftController()
        let dt = blockOut / rate
        var overshoot = 0.0
        var lowest = Double.infinity

        for iteration in 0..<6_000 { // ~64 s
            let step = controller.update(
                errorSeconds: (fill - target) / rate,
                elapsedSeconds: dt
            )
            fill += blockOut * (1 + drift) - blockOut * step
            if iteration > 500 {
                lowest = min(lowest, fill)
                if fill < target { overshoot = max(overshoot, target - fill) }
            }
        }

        // Settles into the deadband and never drops below the target by more
        // than the band itself.
        XCTAssertLessThan(abs(fill - target), controller.deadbandSeconds * rate + 5)
        XCTAssertLessThan(overshoot, controller.deadbandSeconds * rate + 5)
        XCTAssertGreaterThan(lowest, target - controller.deadbandSeconds * rate - 5)
    }

    func testCorrectionTracksTheDriftRate() {
        let drift = 150e-6
        let target = 960.0
        var fill = target
        var controller = DriftController()
        let dt = blockOut / rate

        for _ in 0..<2_000 {
            let step = controller.update(
                errorSeconds: (fill - target) / rate,
                elapsedSeconds: dt
            )
            fill += blockOut * (1 + drift) - blockOut * step
        }

        // Inside the deadband the loop stops correcting, so the long-run
        // average correction has to carry the drift.
        XCTAssertEqual(controller.correction, drift, accuracy: drift)
        XCTAssertLessThan(abs(fill - target), 200)
    }

    func testSmoothingLimitsRateJump() {
        var controller = DriftController()
        let dt = blockOut / rate
        _ = controller.update(errorSeconds: 0, elapsedSeconds: dt)
        let before = controller.correction
        _ = controller.update(errorSeconds: 1, elapsedSeconds: dt)
        // One 10 ms step may only move a fraction of the way to the clamp.
        XCTAssertLessThan(controller.correction - before, controller.maxCorrection * 0.1)
    }
}
