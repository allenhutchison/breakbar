import XCTest
@testable import BreakBarCore

final class BreakBarPresentationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)
    private let policy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20
    )

    func testWarningUsesMacCountdownDeadline() {
        let state = BreakBarState(
            phase: .focusing,
            enforcement: .warning,
            phaseStartedAt: origin,
            focusDueAt: origin.addingTimeInterval(60),
            revision: 2
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(50)
        )

        XCTAssertEqual(presentation.shortLabel, "0:10")
        XCTAssertEqual(
            presentation.timer,
            BreakBarTimerPresentation(direction: .countDown, interval: 10)
        )
        XCTAssertEqual(presentation.tone, .warning)
    }

    func testBreakCountsUpAfterMinimum() {
        let state = BreakBarState(
            phase: .onBreak,
            phaseStartedAt: origin,
            minimumBreakEndsAt: origin.addingTimeInterval(20),
            revision: 3
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(27)
        )

        XCTAssertEqual(presentation.shortLabel, "+0:07")
        XCTAssertEqual(
            presentation.timer,
            BreakBarTimerPresentation(direction: .countUp, interval: 7)
        )
        XCTAssertEqual(presentation.primaryActionTitle, "Return to focus")
    }

    func testTimerFormattingIsSharedAcrossStates() {
        XCTAssertEqual(
            BreakBarTimerPresentation(direction: .countDown, interval: 65).text,
            "1:05"
        )
        XCTAssertEqual(
            BreakBarTimerPresentation(direction: .countUp, interval: 65).text,
            "+1:05"
        )
    }
}
