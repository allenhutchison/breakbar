import XCTest
@testable import BreakBarCore

final class ClockedOutReturnDetectorTests: XCTestCase {
    func testReturnAfterClockedOutIdlePromptsOnce() {
        var detector = ClockedOutReturnDetector()

        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 600, idleThreshold: 600)
        )
        XCTAssertTrue(
            detector.update(isClockedOut: true, idleDuration: 1, idleThreshold: 600)
        )
        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 1, idleThreshold: 600)
        )
    }

    func testActiveClockedOutUseDoesNotPromptWithoutAnIdlePeriod() {
        var detector = ClockedOutReturnDetector()

        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 1, idleThreshold: 600)
        )
    }

    func testClockingInClearsObservedIdlePeriod() {
        var detector = ClockedOutReturnDetector()

        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 600, idleThreshold: 600)
        )
        XCTAssertFalse(
            detector.update(isClockedOut: false, idleDuration: 1, idleThreshold: 600)
        )
        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 1, idleThreshold: 600)
        )
    }

    func testResetDismissesPendingReturn() {
        var detector = ClockedOutReturnDetector()

        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 600, idleThreshold: 600)
        )
        detector.reset()
        XCTAssertFalse(
            detector.update(isClockedOut: true, idleDuration: 1, idleThreshold: 600)
        )
    }
}
