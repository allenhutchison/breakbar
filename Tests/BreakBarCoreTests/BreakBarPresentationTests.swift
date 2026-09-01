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

    func testActiveMeetingReplacesBreakEnforcementCountdown() {
        let state = BreakBarState(
            phase: .focusing,
            enforcement: .none,
            phaseStartedAt: origin,
            nominalFocusDueAt: origin.addingTimeInterval(60),
            focusDueAt: origin.addingTimeInterval(105),
            breakPlanReason: .deferredThroughMeeting,
            calendarMeetingStartsAt: origin.addingTimeInterval(50),
            calendarMeetingEndsAt: origin.addingTimeInterval(90),
            revision: 3
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(70)
        )

        XCTAssertEqual(presentation.shortLabel, "0:20")
        XCTAssertEqual(presentation.title, "In a meeting")
        XCTAssertEqual(presentation.tone, .meeting)
        XCTAssertNil(presentation.primaryActionTitle)
    }

    func testPulledBreakExplainsCalendarAdjustment() {
        let state = BreakBarState(
            phase: .focusing,
            phaseStartedAt: origin,
            nominalFocusDueAt: origin.addingTimeInterval(60),
            focusDueAt: origin.addingTimeInterval(50),
            breakPlanReason: .pulledBeforeMeeting,
            revision: 2
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin
        )

        XCTAssertTrue(presentation.detail.contains("moved before your next meeting"))
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
