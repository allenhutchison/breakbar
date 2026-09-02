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

    func testTravelAndOffsiteEventsDoNotAffectBreakPlanning() {
        let travel = BreakCalendarConstraint(
            id: "travel",
            startAt: date(50),
            endAt: date(90),
            kind: .travel
        )
        let offsite = BreakCalendarConstraint(
            id: "offsite",
            startAt: date(90),
            endAt: date(140),
            kind: .offsiteMeeting
        )

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: origin,
            now: origin,
            policy: policy,
            constraints: [travel, offsite]
        )

        XCTAssertEqual(plan.plannedBreakAt, date(60))
        XCTAssertNil(plan.meetingStartsAt)
    }

    func testTravelChainIncludesAdjacentOffsiteAndReturnTravel() throws {
        let outbound = BreakCalendarConstraint(
            id: "outbound", startAt: date(600), endAt: date(900), kind: .travel
        )
        let offsite = BreakCalendarConstraint(
            id: "offsite", startAt: date(960), endAt: date(1_500), kind: .offsiteMeeting
        )
        let returnTrip = BreakCalendarConstraint(
            id: "return", startAt: date(1_560), endAt: date(1_800), kind: .travel
        )
        let unrelated = BreakCalendarConstraint(
            id: "later", startAt: date(3_000), endAt: date(3_100), kind: .offsiteMeeting
        )

        let chain = try XCTUnwrap(
            BreakTravelPlanner.nextChain(
                in: [unrelated, returnTrip, outbound, offsite],
                at: origin
            )
        )

        XCTAssertEqual(chain.map(\.id), ["outbound", "offsite", "return"])
        XCTAssertEqual(BreakTravelPlanner.activeKind(in: chain, at: date(1_000)), .offsiteMeeting)
    }

    func testMeetingBetweenTravelBlocksIsTreatedAsOffsite() throws {
        let outbound = BreakCalendarConstraint(
            id: "outbound", startAt: date(600), endAt: date(900), kind: .travel
        )
        let meeting = BreakCalendarConstraint(
            id: "client", startAt: date(900), endAt: date(1_500)
        )
        let returnTrip = BreakCalendarConstraint(
            id: "return", startAt: date(1_500), endAt: date(1_800), kind: .travel
        )

        let chain = try XCTUnwrap(
            BreakTravelPlanner.nextChain(in: [outbound, meeting, returnTrip], at: origin)
        )

        XCTAssertEqual(chain.map(\.kind), [.travel, .offsiteMeeting, .travel])
    }

    func testCalendarClassifierDistinguishesTravelOffsiteAndVirtualMeetings() {
        XCTAssertEqual(
            BreakCalendarClassifier.classify(title: "Drive to client office"),
            .travel
        )
        XCTAssertEqual(
            BreakCalendarClassifier.classify(title: "Planning", location: "500 Market Street"),
            .offsiteMeeting
        )
        XCTAssertEqual(
            BreakCalendarClassifier.classify(
                title: "Standup",
                location: "https://meet.google.com/abc-defg-hij"
            ),
            .meeting
        )
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
