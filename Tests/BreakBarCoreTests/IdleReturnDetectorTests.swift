import XCTest
@testable import BreakBarCore

final class IdleReturnDetectorTests: XCTestCase {
    func testReturnAfterTrackedIdlePromptsOnce() {
        var detector = IdleReturnDetector()

        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 600,
                idleThreshold: 600
            )
        )
        XCTAssertTrue(
            detector.update(
                isTracking: true,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
    }

    func testActiveTrackingDoesNotPromptWithoutAnIdlePeriod() {
        var detector = IdleReturnDetector()

        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
    }

    func testPromptWaitsUntilReturnIsEligible() {
        var detector = IdleReturnDetector()

        XCTAssertFalse(
            detector.update(
                isTracking: true,
                canPrompt: false,
                idleDuration: 600,
                idleThreshold: 600
            )
        )
        XCTAssertFalse(
            detector.update(
                isTracking: true,
                canPrompt: false,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
        XCTAssertTrue(
            detector.update(
                isTracking: true,
                canPrompt: true,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
    }

    func testStoppingTrackingClearsObservedIdlePeriod() {
        var detector = IdleReturnDetector()

        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 600,
                idleThreshold: 600
            )
        )
        XCTAssertFalse(
            detector.update(
                isTracking: false,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
    }

    func testResetDismissesPendingReturn() {
        var detector = IdleReturnDetector()

        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 600,
                idleThreshold: 600
            )
        )
        detector.reset()
        XCTAssertFalse(
            detector.update(
                isTracking: true,
                idleDuration: 1,
                idleThreshold: 600
            )
        )
    }
}
