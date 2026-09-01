import XCTest
@testable import BreakBarCore

final class BreakBarEngineTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)
    private let policy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20
    )

    func testFocusMovesThroughWarningAndRequired() {
        var engine = BreakBarEngine(policy: policy)

        XCTAssertEqual(engine.handle(.clockIn, at: origin), .changed)
        XCTAssertEqual(engine.state.enforcement, .none)

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(45)), .changed)
        XCTAssertEqual(engine.state.enforcement, .warning)

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(60)), .changed)
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testBreakCannotEndBeforeMinimum() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin.addingTimeInterval(60))

        XCTAssertEqual(
            engine.handle(.returnToFocus, at: origin.addingTimeInterval(70)),
            .rejected(remaining: 10)
        )
        XCTAssertEqual(engine.state.phase, .onBreak)
    }

    func testValidReturnStartsFreshFocusCycle() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin.addingTimeInterval(60))
        let returnedAt = origin.addingTimeInterval(80)

        XCTAssertEqual(engine.handle(.returnToFocus, at: returnedAt), .changed)
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(60))
    }

    func testClockOutClearsDeadlinesFromAnyActivePhase() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin)

        XCTAssertEqual(engine.handle(.clockOut, at: origin), .changed)
        XCTAssertEqual(engine.state.phase, .clockedOut)
        XCTAssertNil(engine.state.focusDueAt)
        XCTAssertNil(engine.state.minimumBreakEndsAt)
    }

    func testRepeatedTickIsIdempotent() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let warningTime = origin.addingTimeInterval(50)

        XCTAssertEqual(engine.handle(.tick, at: warningTime), .changed)
        let revision = engine.state.revision
        XCTAssertEqual(engine.handle(.tick, at: warningTime), .unchanged)
        XCTAssertEqual(engine.state.revision, revision)
    }

    func testLifecycleReconciliationAdvancesPastMissedDeadline() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)

        XCTAssertEqual(
            engine.handle(.reconcile, at: origin.addingTimeInterval(90)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .required)
        XCTAssertEqual(engine.state.lastTransitionReason, .lifecycleReconciliation)
    }

    func testClockRollbackDoesNotWeakenVisibleEnforcement() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(50))
        let revision = engine.state.revision

        XCTAssertEqual(
            engine.handle(.reconcile, at: origin.addingTimeInterval(10)),
            .unchanged
        )
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.state.revision, revision)
    }

    func testCalendarPullsBreakBeforeMeeting() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(70),
            endAt: origin.addingTimeInterval(120)
        )

        XCTAssertEqual(
            engine.handle(.updateCalendarConstraints([meeting]), at: origin),
            .changed
        )
        XCTAssertEqual(engine.state.nominalFocusDueAt, origin.addingTimeInterval(60))
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(50))
        XCTAssertEqual(engine.state.breakPlanReason, .pulledBeforeMeeting)
    }

    func testActiveMeetingSuppressesVisibleEnforcement() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(50))
        XCTAssertEqual(engine.state.enforcement, .warning)

        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(50),
            endAt: origin.addingTimeInterval(90)
        )
        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([meeting]),
                at: origin.addingTimeInterval(50)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.lastTransitionReason, .scheduledMeetingStarted)

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(70)),
            .unchanged
        )
        XCTAssertEqual(engine.state.enforcement, .none)
    }

    func testActiveMeetingWindowSurvivesTransientEmptyCalendarRefresh() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(50),
            endAt: origin.addingTimeInterval(90)
        )
        _ = engine.handle(
            .updateCalendarConstraints([meeting]),
            at: origin.addingTimeInterval(50)
        )

        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([]),
                at: origin.addingTimeInterval(70)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(105))
        XCTAssertEqual(engine.state.calendarMeetingStartsAt, meeting.startAt)
        XCTAssertEqual(engine.state.calendarMeetingEndsAt, meeting.endAt)
        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(70)),
            .unchanged
        )
    }

    func testMeetingStartSuppressesAlreadyRequiredBreak() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        XCTAssertEqual(engine.state.enforcement, .required)

        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(85),
            endAt: origin.addingTimeInterval(120)
        )
        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([meeting]),
                at: origin.addingTimeInterval(85)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.lastTransitionReason, .scheduledMeetingStarted)
    }

    func testOverdueMeetingEndStartsFreshFullWarning() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(50),
            endAt: origin.addingTimeInterval(90)
        )
        _ = engine.handle(
            .updateCalendarConstraints([meeting]),
            at: origin.addingTimeInterval(50)
        )

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(90)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(105))
        XCTAssertEqual(engine.state.breakPlanReason, .postMeetingWarning)
        XCTAssertEqual(engine.state.lastTransitionReason, .scheduledMeetingEnded)

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(91)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .warning)

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(105)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testLiveCallSuppressesAlreadyRequiredBreak() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        XCTAssertEqual(engine.state.enforcement, .required)

        let signal = BreakCallSignal(
            bundleIdentifier: "us.zoom.xos",
            confidence: .dedicatedApplication
        )
        XCTAssertEqual(
            engine.handle(.updateCallActivity(signal), at: origin.addingTimeInterval(61)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.liveCallStartedAt, origin.addingTimeInterval(61))
        XCTAssertEqual(engine.state.liveCallBundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(engine.state.lastTransitionReason, .liveCallStarted)
    }

    func testLiveMeetingOverrunDefersBreakUntilCallActuallyEnds() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(50),
            endAt: origin.addingTimeInterval(90)
        )
        _ = engine.handle(
            .updateCalendarConstraints([meeting]),
            at: origin.addingTimeInterval(50)
        )
        let signal = BreakCallSignal(
            bundleIdentifier: "com.google.Chrome",
            confidence: .calendarCorrelatedBrowser
        )
        _ = engine.handle(
            .updateCallActivity(signal),
            at: origin.addingTimeInterval(52)
        )

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(100)),
            .unchanged
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.calendarMeetingEndsAt, meeting.endAt)

        let callEndedAt = origin.addingTimeInterval(110)
        XCTAssertEqual(
            engine.handle(.updateCallActivity(nil), at: callEndedAt),
            .changed
        )
        XCTAssertNil(engine.state.liveCallStartedAt)
        XCTAssertEqual(engine.state.focusDueAt, callEndedAt.addingTimeInterval(15))
        XCTAssertEqual(engine.state.breakPlanReason, .postMeetingWarning)
        XCTAssertEqual(engine.state.lastTransitionReason, .liveCallEnded)

        XCTAssertEqual(engine.handle(.tick, at: callEndedAt), .changed)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(
            engine.handle(.tick, at: callEndedAt.addingTimeInterval(15)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testStartingBreakClearsLiveCallState() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(
            .updateCallActivity(
                BreakCallSignal(
                    bundleIdentifier: "com.apple.FaceTime",
                    confidence: .dedicatedApplication
                )
            ),
            at: origin.addingTimeInterval(10)
        )

        XCTAssertEqual(
            engine.handle(.startBreak, at: origin.addingTimeInterval(20)),
            .changed
        )
        XCTAssertNil(engine.state.liveCallStartedAt)
        XCTAssertNil(engine.state.liveCallBundleIdentifier)
        XCTAssertNil(engine.state.liveCallConfidence)
    }

    func testEmergencyActionsRecordDistinctReasons() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)

        XCTAssertEqual(
            engine.handle(.emergencyStartBreak, at: origin.addingTimeInterval(60)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .onBreak)
        XCTAssertEqual(engine.state.lastTransitionReason, .emergencyStartBreak)

        XCTAssertEqual(
            engine.handle(.emergencyClockOut, at: origin.addingTimeInterval(61)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .clockedOut)
        XCTAssertEqual(engine.state.lastTransitionReason, .emergencyClockOut)
    }

    func testStateDecodesSnapshotWithoutTransitionReason() throws {
        let data = Data(
            """
            {
              "phase": "clockedOut",
              "enforcement": "none",
              "revision": 3
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(BreakBarState.self, from: data)
        XCTAssertEqual(state.phase, .clockedOut)
        XCTAssertEqual(state.revision, 3)
        XCTAssertNil(state.lastTransitionReason)
    }
}
