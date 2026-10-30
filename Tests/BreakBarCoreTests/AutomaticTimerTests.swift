import Foundation
import XCTest
@testable import BreakBarCore

final class AutomaticTimerTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let policy = BreakPolicy(focusDuration: 60, warningDuration: 15, minimumBreakDuration: 20, idleThreshold: 10)

    func testLeavingRequiredPromptStartsBreakAtLastInputAndEnforcesRemainingMinimum() throws {
        var engine = BreakBarEngine()
        _ = engine.handle(.resumeReminders, at: origin)
        let due = origin.addingTimeInterval(engine.policy.focusDuration)
        _ = engine.handle(.tick, at: due)
        XCTAssertEqual(engine.state.enforcement, .required)
        for idle in [0.0, 29, -1, .infinity, .nan] {
            XCTAssertEqual(engine.handle(.observeActivity(idleDuration: idle), at: due.addingTimeInterval(29)), .unchanged)
        }
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 30), at: due.addingTimeInterval(30)), .changed)
        XCTAssertEqual(engine.state.phase, .onBreak)
        XCTAssertEqual(engine.state.phaseStartedAt, due)
        XCTAssertEqual(engine.state.minimumBreakEndsAt, due.addingTimeInterval(300))
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.lastTransitionReason, .idleThresholdReached)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 90), at: due.addingTimeInterval(90)), .unchanged)

        let saved = try JSONEncoder().encode(engine.state)
        engine = BreakBarEngine(state: try JSONDecoder().decode(BreakBarState.self, from: saved))
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: due.addingTimeInterval(299)), .rejected(remaining: 1))
        XCTAssertEqual(engine.state.phase, .onBreak)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: due.addingTimeInterval(300)), .changed)
        XCTAssertEqual(engine.state.focusDueAt, due.addingTimeInterval(300 + engine.policy.focusDuration))
    }

    func testDelayedIdleObservationCreditsWholeAbsenceAndShortPoliciesStillWork() {
        for timing in [BreakPolicy.standard, policy] {
            var engine = BreakBarEngine(policy: timing)
            _ = engine.handle(.resumeReminders, at: origin)
            let due = origin.addingTimeInterval(timing.focusDuration)
            _ = engine.handle(.tick, at: due)
            let returnedAt = due.addingTimeInterval(timing.minimumBreakDuration + 10)
            XCTAssertEqual(engine.handle(.observeActivity(idleDuration: timing.minimumBreakDuration + 10), at: returnedAt), .changed)
            XCTAssertEqual(engine.state.phase, .onBreak)
            XCTAssertEqual(engine.state.phaseStartedAt, due)
            XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: returnedAt), .changed)
            XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(timing.focusDuration))
        }
    }

    func testBriefInactivityBeforeRequiredPromptDoesNotStartBreak() {
        var engine = BreakBarEngine()
        _ = engine.handle(.resumeReminders, at: origin)
        let warningAt = origin.addingTimeInterval(engine.policy.focusDuration - engine.policy.warningDuration)
        _ = engine.handle(.tick, at: warningAt)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 30), at: warningAt.addingTimeInterval(30)), .unchanged)
        XCTAssertEqual(engine.state.phase, .focusing)
    }

    func testStartsOnlyOnActivityAndExplicitPauseSurvivesRecovery() throws {
        var engine = BreakBarEngine(policy: policy)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 30), at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin), .changed)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(60))
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(1)), .unchanged)
        XCTAssertEqual(engine.handle(.pauseReminders, at: origin.addingTimeInterval(2)), .changed)
        let saved = try JSONEncoder().encode(engine.state)
        engine = BreakBarEngine(state: try JSONDecoder().decode(BreakBarState.self, from: saved), policy: policy)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(3)), .unchanged)
        XCTAssertEqual(engine.state.phase, .clockedOut)
        XCTAssertEqual(engine.handle(.resumeReminders, at: origin.addingTimeInterval(4)), .changed)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(64))
        XCTAssertEqual(engine.handle(.resumeReminders, at: origin.addingTimeInterval(5)), .unchanged)
    }

    func testAwayReturnResumesAutomaticallyAndShortAbsencePreservesDeadline() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.observeActivity(idleDuration: 0), at: origin)
        _ = engine.handle(.observeActivity(idleDuration: 10), at: origin.addingTimeInterval(20))
        XCTAssertEqual(engine.state.phase, .awayUnclassified)
        _ = engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(21))
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(60))
        _ = engine.handle(.observeActivity(idleDuration: 30), at: origin.addingTimeInterval(51))
        _ = engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(52))
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(112))
        XCTAssertNil(engine.state.awayReturnDetectedAt)
    }

    func testActivityDoesNotEndBreakBeforeMinimumOrInterruptMeeting() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.resumeReminders, at: origin)
        _ = engine.handle(.startBreak, at: origin)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(19)), .rejected(remaining: 1))
        XCTAssertEqual(engine.state.phase, .onBreak)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(20)), .changed)
        let meeting = BreakCalendarConstraint(id: "meeting", startAt: origin, endAt: origin.addingTimeInterval(100))
        _ = engine.handle(.updateCalendarConstraints([meeting]), at: origin.addingTimeInterval(21))
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 30), at: origin.addingTimeInterval(51)), .unchanged)
        XCTAssertEqual(engine.state.phase, .focusing)
    }

    func testShortenedMeetingUsesNewEndAndGivesFullWarning() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.resumeReminders, at: origin)
        let meeting = BreakCalendarConstraint(id: "meeting", startAt: origin.addingTimeInterval(50), endAt: origin.addingTimeInterval(120))
        _ = engine.handle(.updateCalendarConstraints([meeting]), at: origin.addingTimeInterval(50))
        let shortened = BreakCalendarConstraint(id: "meeting", startAt: meeting.startAt, endAt: origin.addingTimeInterval(75))
        _ = engine.handle(.updateCalendarConstraints([shortened]), at: origin.addingTimeInterval(70))
        XCTAssertEqual(engine.state.calendarMeetingEndsAt, shortened.endAt)
        _ = engine.handle(.updateCalendarConstraints([]), at: origin.addingTimeInterval(75))
        _ = engine.handle(.tick, at: origin.addingTimeInterval(75))
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(90))
    }

    func testShortenedIntoPastAndMovedMeetingReleaseSuppression() {
        for newStart in [0.0, 150.0] {
            var engine = BreakBarEngine(policy: policy)
            _ = engine.handle(.resumeReminders, at: origin)
            let meeting = BreakCalendarConstraint(id: "meeting", startAt: origin.addingTimeInterval(50), endAt: origin.addingTimeInterval(120))
            _ = engine.handle(.updateCalendarConstraints([meeting]), at: origin.addingTimeInterval(50))
            let changed = BreakCalendarConstraint(id: "meeting", startAt: origin.addingTimeInterval(newStart), endAt: origin.addingTimeInterval(newStart + 55))
            _ = engine.handle(.updateCalendarConstraints([changed]), at: origin.addingTimeInterval(70))
            _ = engine.handle(.tick, at: origin.addingTimeInterval(70))
            XCTAssertEqual(engine.state.enforcement, .warning)
            XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(85))
        }
    }

    func testRemovingOrMovingUpcomingMeetingDoesNotWeakenRequiredBreak() {
        for refreshedMeetings in [
            [],
            [BreakCalendarConstraint(
                id: "meeting",
                startAt: origin.addingTimeInterval(300),
                endAt: origin.addingTimeInterval(400)
            )],
        ] {
            var engine = BreakBarEngine(policy: policy)
            _ = engine.handle(.resumeReminders, at: origin)
            _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
            XCTAssertEqual(engine.state.enforcement, .required)
            let upcoming = BreakCalendarConstraint(
                id: "meeting",
                startAt: origin.addingTimeInterval(75),
                endAt: origin.addingTimeInterval(120)
            )
            _ = engine.handle(.updateCalendarConstraints([upcoming]), at: origin.addingTimeInterval(70))
            XCTAssertEqual(engine.state.calendarMeetingStartsAt, upcoming.startAt)
            XCTAssertEqual(engine.state.enforcement, .required)
            let requiredDeadline = engine.state.focusDueAt
            _ = engine.handle(.updateCalendarConstraints(refreshedMeetings), at: origin.addingTimeInterval(71))
            XCTAssertEqual(engine.state.enforcement, .required)
            XCTAssertEqual(engine.state.focusDueAt, requiredDeadline)
            XCTAssertNotEqual(engine.state.breakPlanReason, .postMeetingWarning)
            _ = engine.handle(.tick, at: origin.addingTimeInterval(72))
            XCTAssertEqual(engine.state.enforcement, .required)
        }
    }

    func testDeletionDoesNotInterruptLiveCallAndCallEndGetsWarning() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.resumeReminders, at: origin)
        let meeting = BreakCalendarConstraint(id: "meeting", startAt: origin.addingTimeInterval(50), endAt: origin.addingTimeInterval(120))
        _ = engine.handle(.updateCalendarConstraints([meeting]), at: origin.addingTimeInterval(50))
        _ = engine.handle(.updateCallActivity(BreakCallSignal(bundleIdentifier: "us.zoom.xos", confidence: .dedicatedApplication)), at: origin.addingTimeInterval(50))
        _ = engine.handle(.updateCalendarConstraints([]), at: origin.addingTimeInterval(70))
        _ = engine.handle(.tick, at: origin.addingTimeInterval(70))
        XCTAssertEqual(engine.state.enforcement, .none)
        _ = engine.handle(.updateCallActivity(nil), at: origin.addingTimeInterval(71))
        _ = engine.handle(.tick, at: origin.addingTimeInterval(71))
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(86))
    }
}
