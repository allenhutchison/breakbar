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

    func testRequiredBreakCanBeDeferredWithoutRestartingFocus() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        let focusStartedAt = engine.state.phaseStartedAt
        let nominalDueAt = engine.state.nominalFocusDueAt

        XCTAssertEqual(
            engine.handle(.deferBreak(by: 300), at: origin.addingTimeInterval(60)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.state.phaseStartedAt, focusStartedAt)
        XCTAssertEqual(engine.state.nominalFocusDueAt, nominalDueAt)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(360))
        XCTAssertEqual(engine.state.breakPlanReason, .userDeferred)
        XCTAssertEqual(engine.state.lastTransitionReason, .breakDeferred)

        let revision = engine.state.revision
        XCTAssertEqual(
            engine.handle(.deferBreak(by: 300), at: origin.addingTimeInterval(60)),
            .unchanged
        )
        XCTAssertEqual(engine.state.revision, revision)
    }

    func testBreakDeferralRequiresARequiredBreakAndPositiveDuration() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)

        XCTAssertEqual(engine.handle(.deferBreak(by: 300), at: origin), .unchanged)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        XCTAssertEqual(
            engine.handle(.deferBreak(by: 0), at: origin.addingTimeInterval(60)),
            .unchanged
        )
    }

    func testCalendarRefreshPreservesActiveBreakDeferral() {
        let boundedPolicy = BreakPolicy(
            focusDuration: 60,
            warningDuration: 15,
            minimumBreakDuration: 20,
            maximumSeatedDuration: 90
        )
        var engine = BreakBarEngine(policy: boundedPolicy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        _ = engine.handle(.deferBreak(by: 300), at: origin.addingTimeInterval(60))

        XCTAssertEqual(
            engine.handle(.updateCalendarConstraints([]), at: origin.addingTimeInterval(61)),
            .unchanged
        )
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(360))
        XCTAssertEqual(engine.state.enforcement, .warning)
    }

    func testCorrectingInitialClockInRecalculatesFocusDeadline() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let correctedStart = origin.addingTimeInterval(-20)

        XCTAssertEqual(
            engine.handle(
                .correctClockIn(
                    from: origin,
                    to: correctedStart,
                    adjustsCurrentFocusCycle: true
                ),
                at: origin.addingTimeInterval(10)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.phaseStartedAt, correctedStart)
        XCTAssertEqual(engine.state.nominalFocusDueAt, origin.addingTimeInterval(40))
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(40))
        XCTAssertEqual(engine.state.lastTransitionReason, .correctClockIn)
    }

    func testCorrectingClockInDoesNotRewriteLaterFocusCycle() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin.addingTimeInterval(60))
        let returnedAt = origin.addingTimeInterval(80)
        _ = engine.handle(.returnToFocus, at: returnedAt)

        XCTAssertEqual(
            engine.handle(
                .correctClockIn(
                    from: origin,
                    to: origin.addingTimeInterval(-20),
                    adjustsCurrentFocusCycle: false
                ),
                at: origin.addingTimeInterval(90)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.phaseStartedAt, returnedAt)
        XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(60))
        XCTAssertEqual(engine.state.lastTransitionReason, .correctClockIn)
    }

    func testCorrectingInitialClockInRepairsMismatchedTimerAnchor() {
        let staleTimerStart = origin.addingTimeInterval(-20)
        var engine = BreakBarEngine(
            state: BreakBarState(
                phase: .focusing,
                phaseStartedAt: staleTimerStart,
                nominalFocusDueAt: staleTimerStart.addingTimeInterval(policy.focusDuration),
                focusDueAt: staleTimerStart.addingTimeInterval(policy.focusDuration)
            ),
            policy: policy
        )
        let ledgerStart = origin
        let correctedStart = origin.addingTimeInterval(-40)

        XCTAssertEqual(
            engine.handle(
                .correctClockIn(
                    from: ledgerStart,
                    to: correctedStart,
                    adjustsCurrentFocusCycle: true
                ),
                at: origin.addingTimeInterval(10)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.phaseStartedAt, correctedStart)
        XCTAssertEqual(
            engine.state.focusDueAt,
            correctedStart.addingTimeInterval(policy.focusDuration)
        )
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

    func testInfeasibleMeetingDeferralIsCappedAtMaximumSeatedDeadline() {
        let boundedPolicy = BreakPolicy(
            focusDuration: 60,
            warningDuration: 15,
            minimumBreakDuration: 20,
            maximumSeatedDuration: 90
        )
        var engine = BreakBarEngine(policy: boundedPolicy)
        _ = engine.handle(.clockIn, at: origin)
        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(70),
            endAt: origin.addingTimeInterval(120)
        )

        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([meeting]),
                at: origin.addingTimeInterval(36)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(90))
        XCTAssertEqual(engine.state.breakPlanReason, .maximumSeatedLimit)

        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([meeting]),
                at: origin.addingTimeInterval(70)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(90))
        XCTAssertEqual(engine.state.breakPlanReason, .maximumSeatedLimit)

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(120)),
            .changed
        )
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(135))
        XCTAssertEqual(engine.state.breakPlanReason, .postMeetingWarning)
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

    func testScheduledMeetingEndPreservesFutureBreakDeferral() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        _ = engine.handle(.deferBreak(by: 300), at: origin.addingTimeInterval(60))
        let deferredDueAt = origin.addingTimeInterval(360)
        let meeting = BreakCalendarConstraint(
            id: "meeting",
            startAt: origin.addingTimeInterval(100),
            endAt: origin.addingTimeInterval(200)
        )

        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([meeting]),
                at: origin.addingTimeInterval(100)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.focusDueAt, deferredDueAt)
        XCTAssertEqual(engine.state.breakPlanReason, .userDeferred)

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(200)),
            .changed
        )
        XCTAssertEqual(engine.state.focusDueAt, deferredDueAt)
        XCTAssertEqual(engine.state.breakPlanReason, .userDeferred)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(201)), .unchanged)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(359)), .unchanged)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.tick, at: deferredDueAt), .changed)
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

    func testLiveCallEndPreservesFutureBreakDeferral() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        _ = engine.handle(.deferBreak(by: 300), at: origin.addingTimeInterval(60))
        let deferredDueAt = origin.addingTimeInterval(360)
        let signal = BreakCallSignal(
            bundleIdentifier: "us.zoom.xos",
            confidence: .dedicatedApplication
        )
        _ = engine.handle(.updateCallActivity(signal), at: origin.addingTimeInterval(100))

        XCTAssertEqual(
            engine.handle(.updateCallActivity(nil), at: origin.addingTimeInterval(200)),
            .changed
        )
        XCTAssertEqual(engine.state.focusDueAt, deferredDueAt)
        XCTAssertEqual(engine.state.breakPlanReason, .userDeferred)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(200)), .unchanged)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(359)), .unchanged)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.tick, at: deferredDueAt), .changed)
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

    func testLunchSuspendsBreakEnforcementAndClearsDeadlines() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(50))
        XCTAssertEqual(engine.state.enforcement, .warning)

        let lunchStartedAt = origin.addingTimeInterval(51)
        XCTAssertEqual(engine.handle(.startLunch, at: lunchStartedAt), .changed)
        XCTAssertEqual(engine.state.phase, .onLunch)
        XCTAssertEqual(engine.state.phaseStartedAt, lunchStartedAt)
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertNil(engine.state.nominalFocusDueAt)
        XCTAssertNil(engine.state.focusDueAt)
        XCTAssertNil(engine.state.minimumBreakEndsAt)
        XCTAssertEqual(engine.state.lastTransitionReason, .startLunch)

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(500)),
            .unchanged
        )
        XCTAssertEqual(engine.state.enforcement, .none)
    }

    func testEndingLunchStartsFreshFocusCycle() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startLunch, at: origin.addingTimeInterval(30))
        let lunchEndedAt = origin.addingTimeInterval(120)

        XCTAssertEqual(engine.handle(.endLunch, at: lunchEndedAt), .changed)
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.phaseStartedAt, lunchEndedAt)
        XCTAssertEqual(engine.state.focusDueAt, lunchEndedAt.addingTimeInterval(60))
        XCTAssertEqual(engine.state.breakPlanReason, .nominal)
        XCTAssertEqual(engine.state.lastTransitionReason, .endLunch)
    }

    func testLunchCanClockOutButCannotUseBreakReturnCommand() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startLunch, at: origin.addingTimeInterval(20))

        XCTAssertEqual(
            engine.handle(.returnToFocus, at: origin.addingTimeInterval(30)),
            .unchanged
        )
        XCTAssertEqual(
            engine.handle(.clockOut, at: origin.addingTimeInterval(40)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .clockedOut)
    }

    func testManualMeetingSuppressesEnforcementAndEndsWithFreshWarningWhenOverdue() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(50))
        XCTAssertEqual(engine.state.enforcement, .warning)

        let meetingStartedAt = origin.addingTimeInterval(51)
        XCTAssertEqual(
            engine.handle(.startManualMeeting, at: meetingStartedAt),
            .changed
        )
        XCTAssertEqual(engine.state.manualMeetingStartedAt, meetingStartedAt)
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(60))

        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(100)),
            .unchanged
        )

        let meetingEndedAt = origin.addingTimeInterval(100)
        XCTAssertEqual(
            engine.handle(.endManualMeeting, at: meetingEndedAt),
            .changed
        )
        XCTAssertNil(engine.state.manualMeetingStartedAt)
        XCTAssertEqual(
            engine.state.focusDueAt,
            meetingEndedAt.addingTimeInterval(policy.warningDuration)
        )
        XCTAssertEqual(engine.state.breakPlanReason, .postMeetingWarning)
        XCTAssertEqual(engine.state.lastTransitionReason, .endManualMeeting)

        XCTAssertEqual(engine.handle(.tick, at: meetingEndedAt), .changed)
        XCTAssertEqual(engine.state.enforcement, .warning)
    }

    func testManualMeetingEndPreservesFutureBreakDeferral() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        _ = engine.handle(.deferBreak(by: 300), at: origin.addingTimeInterval(60))
        let deferredDueAt = origin.addingTimeInterval(360)
        _ = engine.handle(.startManualMeeting, at: origin.addingTimeInterval(100))

        XCTAssertEqual(
            engine.handle(.endManualMeeting, at: origin.addingTimeInterval(200)),
            .changed
        )
        XCTAssertEqual(engine.state.focusDueAt, deferredDueAt)
        XCTAssertEqual(engine.state.breakPlanReason, .userDeferred)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(200)), .unchanged)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(359)), .unchanged)
        XCTAssertEqual(engine.state.enforcement, .warning)
        XCTAssertEqual(engine.handle(.tick, at: deferredDueAt), .changed)
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testManualMeetingEndingBeforeDeadlineResumesOriginalFocusCycle() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startManualMeeting, at: origin.addingTimeInterval(10))

        XCTAssertEqual(
            engine.handle(.endManualMeeting, at: origin.addingTimeInterval(30)),
            .changed
        )
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(60))
        XCTAssertEqual(engine.state.breakPlanReason, .nominal)
        XCTAssertEqual(engine.state.enforcement, .none)
    }

    func testIdleThresholdEntersAwayAtLastInputAndSuspendsEnforcement() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(50))
        XCTAssertEqual(engine.state.enforcement, .warning)

        let awayStartedAt = origin.addingTimeInterval(20)
        XCTAssertEqual(
            engine.handle(
                .idleThresholdReached(idleStartedAt: awayStartedAt),
                at: origin.addingTimeInterval(50)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .awayUnclassified)
        XCTAssertEqual(engine.state.phaseStartedAt, awayStartedAt)
        XCTAssertEqual(engine.state.awayPreviousFocusStartedAt, origin)
        XCTAssertNil(engine.state.awayReturnDetectedAt)
        XCTAssertEqual(engine.state.enforcement, .none)
        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(500)),
            .unchanged
        )
    }

    func testAwayClassificationRequiresReturnAndStartsFreshCycleAtReturnTime() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(
            .idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)),
            at: origin.addingTimeInterval(30)
        )
        XCTAssertEqual(
            engine.handle(.classifyAway(.lunch), at: origin.addingTimeInterval(70)),
            .unchanged
        )

        let returnedAt = origin.addingTimeInterval(80)
        XCTAssertEqual(engine.handle(.userActivityResumed, at: returnedAt), .changed)
        XCTAssertEqual(engine.state.awayReturnDetectedAt, returnedAt)
        XCTAssertEqual(
            engine.handle(.classifyAway(.lunch), at: origin.addingTimeInterval(85)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.phaseStartedAt, returnedAt)
        XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(60))
        XCTAssertEqual(engine.state.lastTransitionReason, .classifyAwayAsLunch)
    }

    func testCountAsWorkRestoresOriginalSeatedCycle() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(
            .idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)),
            at: origin.addingTimeInterval(30)
        )
        _ = engine.handle(.userActivityResumed, at: origin.addingTimeInterval(80))

        XCTAssertEqual(
            engine.handle(.classifyAway(.countAsWork), at: origin.addingTimeInterval(85)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.phaseStartedAt, origin)
        XCTAssertEqual(engine.state.focusDueAt, origin.addingTimeInterval(60))
        XCTAssertEqual(engine.state.lastTransitionReason, .classifyAwayAsWork)
        XCTAssertEqual(
            engine.handle(.tick, at: origin.addingTimeInterval(85)),
            .changed
        )
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testIdleDoesNotOverrideManualMeeting() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startManualMeeting, at: origin.addingTimeInterval(10))

        XCTAssertEqual(
            engine.handle(
                .idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)),
                at: origin.addingTimeInterval(30)
            ),
            .unchanged
        )
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.manualMeetingStartedAt, origin.addingTimeInterval(10))
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

    func testTravelWarningUsesFiveMinuteDepartureWindow() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let travel = BreakCalendarConstraint(
            id: "travel",
            startAt: origin.addingTimeInterval(600),
            endAt: origin.addingTimeInterval(900),
            kind: .travel
        )
        _ = engine.handle(.updateCalendarConstraints([travel]), at: origin)

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(299)), .changed)
        XCTAssertEqual(engine.state.enforcement, .required)

        // A required break outranks the departure warning until travel actually starts.
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(300)), .unchanged)
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testTravelWarningAppearsWhenNoHigherPriorityBreakIsRequired() {
        var engine = BreakBarEngine(policy: BreakPolicy(
            focusDuration: 1_200,
            warningDuration: 60,
            minimumBreakDuration: 20
        ))
        _ = engine.handle(.clockIn, at: origin)
        let travel = BreakCalendarConstraint(
            id: "travel",
            startAt: origin.addingTimeInterval(600),
            endAt: origin.addingTimeInterval(900),
            kind: .travel
        )
        _ = engine.handle(.updateCalendarConstraints([travel]), at: origin)

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(299)), .unchanged)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(300)), .changed)
        XCTAssertEqual(engine.state.enforcement, .travelWarning)
    }

    func testTravelStartOverridesRequiredBreakAndSuspendsScheduler() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(60))
        let travel = BreakCalendarConstraint(
            id: "travel",
            startAt: origin.addingTimeInterval(100),
            endAt: origin.addingTimeInterval(200),
            kind: .travel
        )
        _ = engine.handle(.updateCalendarConstraints([travel]), at: origin.addingTimeInterval(60))

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(100)), .changed)
        XCTAssertEqual(engine.state.phase, .traveling)
        XCTAssertEqual(engine.state.enforcement, .travelRequired)
        XCTAssertNil(engine.state.focusDueAt)

        XCTAssertEqual(engine.handle(.acknowledgeTravel, at: origin.addingTimeInterval(101)), .changed)
        XCTAssertEqual(engine.state.enforcement, .none)
    }

    func testTravelChainMovesThroughOffsiteAndRequiresExplicitReturnHome() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let outbound = BreakCalendarConstraint(
            id: "outbound", startAt: origin.addingTimeInterval(100),
            endAt: origin.addingTimeInterval(200), kind: .travel
        )
        let offsite = BreakCalendarConstraint(
            id: "offsite", startAt: origin.addingTimeInterval(200),
            endAt: origin.addingTimeInterval(300), kind: .offsiteMeeting
        )
        let returning = BreakCalendarConstraint(
            id: "return", startAt: origin.addingTimeInterval(300),
            endAt: origin.addingTimeInterval(400), kind: .travel
        )
        _ = engine.handle(
            .updateCalendarConstraints([outbound, offsite, returning]),
            at: origin
        )
        _ = engine.handle(.tick, at: origin.addingTimeInterval(100))
        _ = engine.handle(.acknowledgeTravel, at: origin.addingTimeInterval(101))

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(200)), .changed)
        XCTAssertEqual(engine.state.phase, .offsiteMeeting)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(300)), .changed)
        XCTAssertEqual(engine.state.phase, .traveling)
        XCTAssertEqual(engine.handle(.returnHome, at: origin.addingTimeInterval(399)), .unchanged)
        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(400)), .unchanged)
        XCTAssertEqual(engine.state.phase, .traveling)

        let returnedAt = origin.addingTimeInterval(420)
        XCTAssertEqual(engine.handle(.returnHome, at: returnedAt), .changed)
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(60))
        XCTAssertNil(engine.state.travelChain)
    }

    func testLateObservedTravelStartsDuringCalendarUpdate() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let travel = BreakCalendarConstraint(
            id: "travel",
            startAt: origin.addingTimeInterval(100),
            endAt: origin.addingTimeInterval(300),
            kind: .travel
        )

        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([travel]),
                at: origin.addingTimeInterval(150)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .traveling)
        XCTAssertEqual(engine.state.enforcement, .travelRequired)
        XCTAssertEqual(engine.state.lastTransitionReason, .travelStarted)
    }

    func testActiveTravelUsesRefreshedChainEndAndDropsRemovedReturn() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let outbound = BreakCalendarConstraint(
            id: "outbound",
            startAt: origin.addingTimeInterval(100),
            endAt: origin.addingTimeInterval(200),
            kind: .travel
        )
        let returning = BreakCalendarConstraint(
            id: "return",
            startAt: origin.addingTimeInterval(300),
            endAt: origin.addingTimeInterval(500),
            kind: .travel
        )
        _ = engine.handle(.updateCalendarConstraints([outbound, returning]), at: origin)
        _ = engine.handle(.tick, at: origin.addingTimeInterval(100))
        _ = engine.handle(.acknowledgeTravel, at: origin.addingTimeInterval(101))

        let shortenedReturn = BreakCalendarConstraint(
            id: "return",
            startAt: origin.addingTimeInterval(300),
            endAt: origin.addingTimeInterval(350),
            kind: .travel
        )
        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([outbound, shortenedReturn]),
                at: origin.addingTimeInterval(150)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.travelChain?.map(\.endAt).max(), shortenedReturn.endAt)

        XCTAssertEqual(
            engine.handle(
                .updateCalendarConstraints([outbound]),
                at: origin.addingTimeInterval(160)
            ),
            .changed
        )
        XCTAssertEqual(engine.state.travelChain?.map(\.id), ["outbound"])
        XCTAssertEqual(
            engine.handle(.returnHome, at: origin.addingTimeInterval(200)),
            .changed
        )
        XCTAssertEqual(engine.state.phase, .focusing)
    }
}
