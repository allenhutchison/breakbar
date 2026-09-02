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

    func testEarlyBreakReturnRemainsUnavailable() {
        let state = BreakBarState(
            phase: .onBreak,
            phaseStartedAt: origin,
            minimumBreakEndsAt: origin.addingTimeInterval(20),
            revision: 3
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(10)
        )

        XCTAssertEqual(presentation.shortLabel, "0:10")
        XCTAssertEqual(presentation.title, "Stay away a little longer")
        XCTAssertNil(presentation.primaryActionTitle)
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

    func testLiveMeetingOverrunCountsUpFromScheduledEnd() {
        let state = BreakBarState(
            phase: .focusing,
            enforcement: .none,
            phaseStartedAt: origin,
            nominalFocusDueAt: origin.addingTimeInterval(60),
            focusDueAt: origin.addingTimeInterval(105),
            breakPlanReason: .deferredThroughMeeting,
            calendarMeetingStartsAt: origin.addingTimeInterval(50),
            calendarMeetingEndsAt: origin.addingTimeInterval(90),
            liveCallStartedAt: origin.addingTimeInterval(52),
            liveCallBundleIdentifier: "com.google.Chrome",
            liveCallConfidence: .calendarCorrelatedBrowser,
            revision: 4
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(100)
        )

        XCTAssertEqual(presentation.shortLabel, "+0:10")
        XCTAssertEqual(presentation.title, "Meeting overrun")
        XCTAssertEqual(presentation.tone, .meeting)
        XCTAssertNil(presentation.primaryActionTitle)
    }

    func testLiveCallBeforeFutureMeetingCountsUpFromCallStart() {
        let state = BreakBarState(
            phase: .focusing,
            phaseStartedAt: origin,
            nominalFocusDueAt: origin.addingTimeInterval(60),
            focusDueAt: origin.addingTimeInterval(50),
            breakPlanReason: .pulledBeforeMeeting,
            calendarMeetingStartsAt: origin.addingTimeInterval(70),
            calendarMeetingEndsAt: origin.addingTimeInterval(120),
            liveCallStartedAt: origin.addingTimeInterval(10),
            liveCallBundleIdentifier: "us.zoom.xos",
            liveCallConfidence: .dedicatedApplication,
            revision: 4
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(20)
        )

        XCTAssertEqual(presentation.shortLabel, "+0:10")
        XCTAssertEqual(presentation.title, "In a call")
        XCTAssertEqual(presentation.tone, .meeting)
    }

    func testLunchCountsUpWithoutMinimumReturnDeadline() {
        let state = BreakBarState(
            phase: .onLunch,
            phaseStartedAt: origin,
            lastTransitionReason: .startLunch,
            revision: 3
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(32 * 60 + 9)
        )

        XCTAssertEqual(presentation.shortLabel, "+32:09")
        XCTAssertEqual(presentation.title, "Lunch")
        XCTAssertEqual(presentation.tone, .lunch)
        XCTAssertEqual(presentation.primaryActionTitle, "End lunch")
    }

    func testManualMeetingCountsUpAndOffersExplicitEndAction() {
        let state = BreakBarState(
            phase: .focusing,
            phaseStartedAt: origin,
            nominalFocusDueAt: origin.addingTimeInterval(60),
            focusDueAt: origin.addingTimeInterval(60),
            manualMeetingStartedAt: origin.addingTimeInterval(10),
            lastTransitionReason: .startManualMeeting,
            revision: 3
        )

        let presentation = BreakBarPresentation(
            state: state,
            policy: policy,
            now: origin.addingTimeInterval(42)
        )

        XCTAssertEqual(presentation.shortLabel, "+0:32")
        XCTAssertEqual(presentation.title, "In a meeting")
        XCTAssertEqual(presentation.tone, .meeting)
        XCTAssertEqual(presentation.primaryActionTitle, "End meeting")
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
