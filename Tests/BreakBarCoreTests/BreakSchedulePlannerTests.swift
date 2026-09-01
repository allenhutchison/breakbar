import XCTest
@testable import BreakBarCore

final class BreakSchedulePlannerTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 2_000_000)
    private let policy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20,
        maximumSeatedDuration: 90
    )

    func testPullsBreakForwardWhenWarningAndMinimumBreakFit() {
        let meeting = constraint(start: 70, end: 120)

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: origin,
            now: origin,
            policy: policy,
            constraints: [meeting]
        )

        XCTAssertEqual(plan.nominalBreakAt, date(60))
        XCTAssertEqual(plan.plannedBreakAt, date(50))
        XCTAssertEqual(plan.reason, .pulledBeforeMeeting)
        XCTAssertEqual(plan.meetingStartsAt, meeting.startAt)
        XCTAssertEqual(plan.meetingEndsAt, meeting.endAt)
    }

    func testDefersWhenFullWarningNoLongerFitsBeforeMeeting() {
        let meeting = constraint(start: 70, end: 120)

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: origin,
            now: date(36),
            policy: policy,
            constraints: [meeting]
        )

        XCTAssertEqual(plan.plannedBreakAt, date(135))
        XCTAssertEqual(plan.reason, .deferredThroughMeeting)
    }

    func testDenseCalendarDoesNotPullIntoAnotherMeeting() {
        let blocker = constraint(id: "blocker", start: 40, end: 48)
        let meeting = constraint(id: "target", start: 70, end: 120)

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: origin,
            now: origin,
            policy: policy,
            constraints: [meeting, blocker]
        )

        XCTAssertEqual(plan.plannedBreakAt, date(135))
        XCTAssertEqual(plan.reason, .deferredThroughMeeting)
    }

    func testMeetingAfterMinimumBreakDoesNotDelayNominalBreak() {
        let meeting = constraint(start: 85, end: 150)

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: origin,
            now: origin,
            policy: policy,
            constraints: [meeting]
        )

        XCTAssertEqual(plan.plannedBreakAt, date(60))
        XCTAssertEqual(plan.reason, .nominal)
        XCTAssertNil(plan.meetingStartsAt)
        XCTAssertNil(plan.meetingEndsAt)
    }

    func testActiveMeetingTakesPrecedenceOverFuturePlanning() {
        let active = constraint(id: "active", start: 10, end: 40)
        let later = constraint(id: "later", start: 70, end: 120)

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: origin,
            now: date(20),
            policy: policy,
            constraints: [later, active]
        )

        XCTAssertEqual(plan.plannedBreakAt, date(60))
        XCTAssertEqual(plan.reason, .nominal)
        XCTAssertEqual(plan.meetingStartsAt, active.startAt)
        XCTAssertEqual(plan.meetingEndsAt, active.endAt)
    }

    private func constraint(
        id: String = "meeting",
        start: TimeInterval,
        end: TimeInterval
    ) -> BreakCalendarConstraint {
        BreakCalendarConstraint(id: id, startAt: date(start), endAt: date(end))
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }
}
