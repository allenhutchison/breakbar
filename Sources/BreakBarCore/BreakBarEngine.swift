import Foundation

public struct BreakBarEngine: Sendable {
    public private(set) var state: BreakBarState
    public var policy: BreakPolicy

    public init(state: BreakBarState = BreakBarState(), policy: BreakPolicy = .standard) {
        self.state = state
        self.policy = policy
    }

    @discardableResult
    public mutating func handle(_ command: BreakCommand, at now: Date) -> BreakCommandResult {
        switch command {
        case .clockIn:
            guard state.phase == .clockedOut else { return .unchanged }
            beginFocus(at: now, reason: .clockIn)
            return .changed

        case .clockOut:
            guard state.phase != .clockedOut else { return .unchanged }
            state = BreakBarState(
                lastTransitionReason: .clockOut,
                revision: state.revision &+ 1
            )
            return .changed

        case .startBreak:
            return startBreak(at: now, reason: .startBreak)

        case .emergencyStartBreak:
            return startBreak(at: now, reason: .emergencyStartBreak)

        case .emergencyClockOut:
            guard state.phase != .clockedOut else { return .unchanged }
            state = BreakBarState(
                lastTransitionReason: .emergencyClockOut,
                revision: state.revision &+ 1
            )
            return .changed

        case let .deferBreak(duration):
            guard state.phase == .focusing,
                  state.enforcement == .required,
                  duration.isFinite,
                  duration > 0
            else { return .unchanged }
            state.enforcement = .warning
            state.focusDueAt = now.addingTimeInterval(duration)
            state.breakPlanReason = .userDeferred
            state.lastTransitionReason = .breakDeferred
            state.revision &+= 1
            return .changed

        case .returnToFocus:
            guard state.phase == .onBreak else { return .unchanged }
            let remaining = max(0, (state.minimumBreakEndsAt ?? now).timeIntervalSince(now))
            guard remaining <= 0 else { return .rejected(remaining: remaining) }
            beginFocus(at: now, reason: .returnToFocus)
            return .changed

        case .acknowledgeTravel:
            guard state.phase == .traveling,
                  state.enforcement == .travelRequired
            else { return .unchanged }
            state.enforcement = .none
            state.lastTransitionReason = .travelAcknowledged
            state.revision &+= 1
            return .changed

        case .returnHome:
            guard state.phase == .traveling || state.phase == .offsiteMeeting,
                  let chainEnd = state.travelChain?.map(\.endAt).max(),
                  now >= chainEnd
            else { return .unchanged }
            beginFocus(at: now, reason: .returnHome)
            return .changed

        case let .correctClockIn(
            previousStartedAt,
            correctedStartedAt,
            adjustsCurrentFocusCycle
        ):
            guard state.phase != .clockedOut,
                  correctedStartedAt < now
            else { return .unchanged }

            if state.phase == .focusing,
               adjustsCurrentFocusCycle || state.phaseStartedAt == previousStartedAt
            {
                let nominalDueAt = correctedStartedAt.addingTimeInterval(policy.focusDuration)
                state.phaseStartedAt = correctedStartedAt
                state.nominalFocusDueAt = nominalDueAt
                state.focusDueAt = nominalDueAt
                state.breakPlanReason = .nominal
                state.enforcement = .none
            }
            if state.awayPreviousFocusStartedAt == previousStartedAt {
                state.awayPreviousFocusStartedAt = correctedStartedAt
            }
            state.lastTransitionReason = .correctClockIn
            state.revision &+= 1
            return .changed

        case .startLunch:
            guard state.phase == .focusing else { return .unchanged }
            beginLunch(at: now)
            return .changed

        case .endLunch:
            guard state.phase == .onLunch else { return .unchanged }
            beginFocus(at: now, reason: .endLunch)
            return .changed

        case .startManualMeeting:
            guard state.phase == .focusing, state.manualMeetingStartedAt == nil else {
                return .unchanged
            }
            beginManualMeeting(at: now)
            return .changed

        case .endManualMeeting:
            guard state.phase == .focusing, state.manualMeetingStartedAt != nil else {
                return .unchanged
            }
            endManualMeeting(at: now)
            return .changed

        case let .idleThresholdReached(idleStartedAt):
            guard state.phase == .focusing,
                  state.manualMeetingStartedAt == nil,
                  state.liveCallStartedAt == nil,
                  !meetingIsActive(at: now)
            else {
                return .unchanged
            }
            beginAway(idleStartedAt: idleStartedAt, observedAt: now)
            return .changed

        case .userActivityResumed:
            guard state.phase == .awayUnclassified,
                  state.awayReturnDetectedAt == nil
            else {
                return .unchanged
            }
            state.awayReturnDetectedAt = now
            state.lastTransitionReason = .userActivityResumed
            state.revision &+= 1
            return .changed

        case let .classifyAway(classification):
            guard state.phase == .awayUnclassified,
                  state.awayReturnDetectedAt != nil
            else {
                return .unchanged
            }
            classifyAway(as: classification, at: now)
            return .changed

        case .tick, .reconcile:
            if let result = updateTravelTimeline(at: now) {
                return result
            }
            return updateEnforcement(
                at: now,
                reason: command == .tick ? .timerDeadline : .lifecycleReconciliation
            )

        case let .updateCalendarConstraints(constraints):
            if let result = updateTravelPlan(constraints, at: now) {
                return result
            }
            return updateCalendarPlan(constraints, at: now)

        case let .updateCallActivity(signal):
            return updateCallActivity(signal, at: now)
        }
    }

    private mutating func startBreak(
        at now: Date,
        reason: BreakTransitionReason
    ) -> BreakCommandResult {
        guard state.phase == .focusing else { return .unchanged }
        state.phase = .onBreak
        state.enforcement = .none
        state.phaseStartedAt = now
        state.nominalFocusDueAt = nil
        state.focusDueAt = nil
        state.minimumBreakEndsAt = now.addingTimeInterval(policy.minimumBreakDuration)
        state.breakPlanReason = nil
        state.calendarMeetingStartsAt = nil
        state.calendarMeetingEndsAt = nil
        state.scheduledMeetingStartedAt = nil
        state.liveCallStartedAt = nil
        state.liveCallBundleIdentifier = nil
        state.liveCallConfidence = nil
        state.manualMeetingStartedAt = nil
        state.awayPreviousFocusStartedAt = nil
        state.awayReturnDetectedAt = nil
        state.lastTransitionReason = reason
        state.revision &+= 1
        return .changed
    }

    private mutating func beginLunch(at now: Date) {
        state.phase = .onLunch
        state.enforcement = .none
        state.phaseStartedAt = now
        state.nominalFocusDueAt = nil
        state.focusDueAt = nil
        state.minimumBreakEndsAt = nil
        state.breakPlanReason = nil
        state.calendarMeetingStartsAt = nil
        state.calendarMeetingEndsAt = nil
        state.scheduledMeetingStartedAt = nil
        state.liveCallStartedAt = nil
        state.liveCallBundleIdentifier = nil
        state.liveCallConfidence = nil
        state.manualMeetingStartedAt = nil
        state.awayPreviousFocusStartedAt = nil
        state.awayReturnDetectedAt = nil
        state.lastTransitionReason = .startLunch
        state.revision &+= 1
    }

    private mutating func beginManualMeeting(at now: Date) {
        state.enforcement = .none
        state.calendarMeetingStartsAt = nil
        state.calendarMeetingEndsAt = nil
        state.scheduledMeetingStartedAt = nil
        state.liveCallStartedAt = nil
        state.liveCallBundleIdentifier = nil
        state.liveCallConfidence = nil
        state.manualMeetingStartedAt = now
        state.lastTransitionReason = .startManualMeeting
        state.revision &+= 1
    }

    private mutating func endManualMeeting(at now: Date) {
        state.manualMeetingStartedAt = nil
        state.enforcement = .none
        let nominalDueAt = state.nominalFocusDueAt
            ?? state.phaseStartedAt?.addingTimeInterval(policy.focusDuration)
            ?? now
        if now >= nominalDueAt {
            state.focusDueAt = now.addingTimeInterval(policy.warningDuration)
            state.breakPlanReason = .postMeetingWarning
        } else {
            state.focusDueAt = nominalDueAt
            state.breakPlanReason = .nominal
        }
        state.lastTransitionReason = .endManualMeeting
        state.revision &+= 1
    }

    private mutating func beginAway(idleStartedAt: Date, observedAt now: Date) {
        let focusStartedAt = state.phaseStartedAt ?? now
        let awayStartedAt = min(now, max(focusStartedAt, idleStartedAt))
        state.phase = .awayUnclassified
        state.enforcement = .none
        state.phaseStartedAt = awayStartedAt
        state.minimumBreakEndsAt = nil
        state.awayPreviousFocusStartedAt = focusStartedAt
        state.awayReturnDetectedAt = nil
        state.lastTransitionReason = .idleThresholdReached
        state.revision &+= 1
    }

    private mutating func classifyAway(as classification: AwayClassification, at now: Date) {
        let returnedAt = min(now, state.awayReturnDetectedAt ?? now)
        if classification == .countAsWork {
            state.phase = .focusing
            state.enforcement = .none
            state.phaseStartedAt = state.awayPreviousFocusStartedAt ?? returnedAt
            state.awayPreviousFocusStartedAt = nil
            state.awayReturnDetectedAt = nil
            state.lastTransitionReason = .classifyAwayAsWork
            state.revision &+= 1
            return
        }

        let reason: BreakTransitionReason
        switch classification {
        case .lunch:
            reason = .classifyAwayAsLunch
        case .breakTime:
            reason = .classifyAwayAsBreak
        case .otherAway:
            reason = .classifyAwayAsOther
        case .countAsWork:
            preconditionFailure("Count-as-work classification returned early")
        }
        beginFocus(at: returnedAt, reason: reason)
    }

    private mutating func updateEnforcement(
        at now: Date,
        reason: BreakTransitionReason
    ) -> BreakCommandResult {
        guard state.phase == .focusing, let dueAt = state.focusDueAt else {
            return .unchanged
        }
        guard state.enforcement != .travelWarning else { return .unchanged }
        if state.manualMeetingStartedAt != nil {
            guard state.enforcement != .none else { return .unchanged }
            state.enforcement = .none
            state.lastTransitionReason = .startManualMeeting
            state.revision &+= 1
            return .changed
        }
        if state.liveCallStartedAt != nil {
            guard state.enforcement != .none else { return .unchanged }
            state.enforcement = .none
            state.lastTransitionReason = .liveCallStarted
            state.revision &+= 1
            return .changed
        }
        if meetingIsActive(at: now) {
            if state.scheduledMeetingStartedAt == nil {
                state.scheduledMeetingStartedAt = max(
                    state.phaseStartedAt ?? now,
                    state.calendarMeetingStartsAt ?? now
                )
                state.enforcement = .none
                state.lastTransitionReason = .scheduledMeetingStarted
                state.revision &+= 1
                return .changed
            }
            guard state.enforcement != .none else { return .unchanged }
            state.enforcement = .none
            state.lastTransitionReason = .scheduledMeetingStarted
            state.revision &+= 1
            return .changed
        }
        if let result = reconcileEndedMeeting(at: now) {
            return result
        }
        let deadlineEnforcement: BreakEnforcement
        if now >= dueAt {
            deadlineEnforcement = .required
        } else if now >= dueAt.addingTimeInterval(-policy.warningDuration) {
            deadlineEnforcement = .warning
        } else {
            deadlineEnforcement = .none
        }

        // Once a warning or required break has been shown, a wall-clock
        // rollback must not silently weaken enforcement.
        let nextEnforcement = maxEnforcement(state.enforcement, deadlineEnforcement)
        guard nextEnforcement != state.enforcement else { return .unchanged }
        state.enforcement = nextEnforcement
        state.lastTransitionReason = reason
        state.revision &+= 1
        return .changed
    }

    private mutating func beginFocus(at now: Date, reason: BreakTransitionReason) {
        state.phase = .focusing
        state.enforcement = .none
        state.phaseStartedAt = now
        let nominalDueAt = now.addingTimeInterval(policy.focusDuration)
        state.nominalFocusDueAt = nominalDueAt
        state.focusDueAt = nominalDueAt
        state.minimumBreakEndsAt = nil
        state.breakPlanReason = .nominal
        state.calendarMeetingStartsAt = nil
        state.calendarMeetingEndsAt = nil
        state.scheduledMeetingStartedAt = nil
        state.liveCallStartedAt = nil
        state.liveCallBundleIdentifier = nil
        state.liveCallConfidence = nil
        state.manualMeetingStartedAt = nil
        state.awayPreviousFocusStartedAt = nil
        state.awayReturnDetectedAt = nil
        state.travelChain = nil
        state.lastTransitionReason = reason
        state.revision &+= 1
    }

    private mutating func updateCalendarPlan(
        _ constraints: [BreakCalendarConstraint],
        at now: Date
    ) -> BreakCommandResult {
        guard state.phase == .focusing, let cycleStartedAt = state.phaseStartedAt else {
            return .unchanged
        }
        guard state.enforcement != .travelWarning else { return .unchanged }
        guard state.manualMeetingStartedAt == nil else { return .unchanged }
        if let result = reconcileEndedMeeting(at: now) {
            return result
        }

        let plan = BreakSchedulePlanner.plan(
            cycleStartedAt: cycleStartedAt,
            now: now,
            policy: policy,
            constraints: constraints
        )
        var calendarMeetingStartsAt = plan.meetingStartsAt
        var calendarMeetingEndsAt = plan.meetingEndsAt
        var calendarMeetingIsActive = plan.meetingIsActive(at: now)
        var plannedBreakAt = plan.plannedBreakAt
        var planReason = plan.reason

        if state.liveCallStartedAt != nil,
           let storedMeetingStartsAt = state.calendarMeetingStartsAt,
           let storedMeetingEndsAt = state.calendarMeetingEndsAt,
           now >= storedMeetingEndsAt
        {
            calendarMeetingStartsAt = storedMeetingStartsAt
            calendarMeetingEndsAt = storedMeetingEndsAt
            plannedBreakAt = storedMeetingEndsAt.addingTimeInterval(policy.warningDuration)
            planReason = .deferredThroughMeeting
        }

        // Once a scheduled meeting begins, retain its known window through the
        // scheduled end even if EventKit briefly returns an empty result.
        if !calendarMeetingIsActive,
           meetingIsActive(at: now),
           let storedMeetingStartsAt = state.calendarMeetingStartsAt,
           let storedMeetingEndsAt = state.calendarMeetingEndsAt
        {
            calendarMeetingStartsAt = storedMeetingStartsAt
            calendarMeetingEndsAt = storedMeetingEndsAt
            calendarMeetingIsActive = true
            if now >= plan.nominalBreakAt {
                plannedBreakAt = storedMeetingEndsAt.addingTimeInterval(policy.warningDuration)
                planReason = .deferredThroughMeeting
            }
        }

        let preservesCurrentDeadline = state.breakPlanReason == .postMeetingWarning
            || state.breakPlanReason == .userDeferred
        if !calendarMeetingIsActive,
           preservesCurrentDeadline,
           let currentDueAt = state.focusDueAt,
           now < currentDueAt
        {
            plannedBreakAt = currentDueAt
            planReason = state.breakPlanReason ?? planReason
        } else if !calendarMeetingIsActive,
                  state.enforcement != .none,
                  let currentDueAt = state.focusDueAt,
                  plannedBreakAt > currentDueAt
        {
            plannedBreakAt = currentDueAt
            planReason = state.breakPlanReason ?? .nominal
        }

        var candidate = state
        candidate.nominalFocusDueAt = plan.nominalBreakAt
        candidate.focusDueAt = plannedBreakAt
        candidate.breakPlanReason = planReason
        candidate.calendarMeetingStartsAt = calendarMeetingStartsAt
        candidate.calendarMeetingEndsAt = calendarMeetingEndsAt
        if calendarMeetingIsActive || state.liveCallStartedAt != nil {
            candidate.enforcement = .none
        }
        if calendarMeetingIsActive, candidate.scheduledMeetingStartedAt == nil {
            candidate.scheduledMeetingStartedAt = max(
                cycleStartedAt,
                calendarMeetingStartsAt ?? now
            )
        }
        guard candidate != state else { return .unchanged }
        candidate.lastTransitionReason = calendarMeetingIsActive
            ? .scheduledMeetingStarted
            : .calendarPlanUpdated
        candidate.revision &+= 1
        state = candidate
        return .changed
    }

    private mutating func reconcileEndedMeeting(at now: Date) -> BreakCommandResult? {
        guard state.liveCallStartedAt == nil else { return nil }
        guard let meetingEndsAt = state.calendarMeetingEndsAt,
              now >= meetingEndsAt
        else {
            return nil
        }

        let nominalDueAt = state.nominalFocusDueAt
            ?? state.phaseStartedAt?.addingTimeInterval(policy.focusDuration)
            ?? now
        state.calendarMeetingStartsAt = nil
        state.calendarMeetingEndsAt = nil
        state.scheduledMeetingStartedAt = nil
        state.enforcement = .none
        if now >= nominalDueAt {
            state.focusDueAt = now.addingTimeInterval(policy.warningDuration)
            state.breakPlanReason = .postMeetingWarning
        } else {
            state.focusDueAt = nominalDueAt
            state.breakPlanReason = .nominal
        }
        state.lastTransitionReason = .scheduledMeetingEnded
        state.revision &+= 1
        return .changed
    }

    private mutating func updateCallActivity(
        _ signal: BreakCallSignal?,
        at now: Date
    ) -> BreakCommandResult {
        guard state.phase == .focusing else { return .unchanged }
        guard state.manualMeetingStartedAt == nil else { return .unchanged }

        if let signal {
            if state.liveCallStartedAt != nil,
               state.liveCallBundleIdentifier == signal.bundleIdentifier,
               state.liveCallConfidence == signal.confidence,
               state.enforcement == .none
            {
                return .unchanged
            }
            if state.liveCallStartedAt == nil {
                state.liveCallStartedAt = now
            }
            state.liveCallBundleIdentifier = signal.bundleIdentifier
            state.liveCallConfidence = signal.confidence
            state.enforcement = .none
            state.lastTransitionReason = .liveCallStarted
            state.revision &+= 1
            return .changed
        }

        guard state.liveCallStartedAt != nil else { return .unchanged }
        state.liveCallStartedAt = nil
        state.liveCallBundleIdentifier = nil
        state.liveCallConfidence = nil
        state.enforcement = .none
        if let meetingEndsAt = state.calendarMeetingEndsAt, now >= meetingEndsAt {
            state.calendarMeetingStartsAt = nil
            state.calendarMeetingEndsAt = nil
            state.scheduledMeetingStartedAt = nil
        }
        let nominalDueAt = state.nominalFocusDueAt
            ?? state.phaseStartedAt?.addingTimeInterval(policy.focusDuration)
            ?? now
        if now >= nominalDueAt {
            state.focusDueAt = now.addingTimeInterval(policy.warningDuration)
            state.breakPlanReason = .postMeetingWarning
        } else {
            state.focusDueAt = nominalDueAt
            state.breakPlanReason = .nominal
        }
        state.lastTransitionReason = .liveCallEnded
        state.revision &+= 1
        return .changed
    }

    private func meetingIsActive(at now: Date) -> Bool {
        guard let startAt = state.calendarMeetingStartsAt,
              let endAt = state.calendarMeetingEndsAt
        else {
            return false
        }
        return startAt <= now && now < endAt
    }

    private func maxEnforcement(
        _ lhs: BreakEnforcement,
        _ rhs: BreakEnforcement
    ) -> BreakEnforcement {
        let rank: [BreakEnforcement: Int] = [
            .none: 0,
            .warning: 1,
            .travelWarning: 2,
            .required: 3,
            .travelRequired: 4,
        ]
        return rank[lhs, default: 0] >= rank[rhs, default: 0] ? lhs : rhs
    }

    private mutating func updateTravelPlan(
        _ constraints: [BreakCalendarConstraint],
        at now: Date
    ) -> BreakCommandResult? {
        guard state.phase != .clockedOut else { return nil }

        if state.phase == .traveling || state.phase == .offsiteMeeting {
            let reconciledChain = reconcileActiveTravelChain(
                with: constraints,
                at: now
            )
            let chainChanged = state.travelChain != reconciledChain
            if chainChanged {
                state.travelChain = reconciledChain
                state.lastTransitionReason = .travelPlanUpdated
                state.revision &+= 1
            }
            return updateTravelTimeline(at: now) ?? (chainChanged ? .changed : nil)
        }

        let chain = BreakTravelPlanner.nextChain(in: constraints, at: now)
        if state.travelChain != chain {
            state.travelChain = chain
            if chain == nil, state.enforcement == .travelWarning {
                state.enforcement = .none
            }
            state.lastTransitionReason = .travelPlanUpdated
            state.revision &+= 1
            return updateTravelTimeline(at: now) ?? .changed
        }
        return updateTravelTimeline(at: now)
    }

    private func reconcileActiveTravelChain(
        with constraints: [BreakCalendarConstraint],
        at now: Date
    ) -> [BreakCalendarConstraint] {
        let storedChain = state.travelChain ?? []
        let refreshedByID = Dictionary(
            constraints.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var reconciled = storedChain.compactMap { stored -> BreakCalendarConstraint? in
            if let refreshed = refreshedByID[stored.id] {
                return refreshed
            }
            if stored.endAt <= now {
                return stored
            }
            if stored.startAt <= now {
                return BreakCalendarConstraint(
                    id: stored.id,
                    startAt: stored.startAt,
                    endAt: now,
                    kind: stored.kind
                )
            }
            return nil
        }

        if let freshChain = BreakTravelPlanner.nextChain(in: constraints, at: now) {
            let anchorEnd = max(now, reconciled.map(\.endAt).max() ?? now)
            if let freshStart = freshChain.map(\.startAt).min(),
               freshStart <= anchorEnd.addingTimeInterval(BreakTravelPlanner.adjacency)
            {
                let existingIDs = Set(reconciled.map(\.id))
                reconciled.append(contentsOf: freshChain.filter { !existingIDs.contains($0.id) })
            }
        }

        return reconciled.sorted {
            if $0.startAt == $1.startAt { return $0.endAt < $1.endAt }
            return $0.startAt < $1.startAt
        }
    }

    private mutating func updateTravelTimeline(at now: Date) -> BreakCommandResult? {
        guard state.phase != .clockedOut,
              let chain = state.travelChain,
              let chainStart = chain.map(\.startAt).min(),
              let chainEnd = chain.map(\.endAt).max()
        else { return nil }

        if state.phase == .traveling || state.phase == .offsiteMeeting {
            let activeKind = BreakTravelPlanner.activeKind(in: chain, at: now)
            let desiredPhase: BreakBarPhase = activeKind == .offsiteMeeting
                ? .offsiteMeeting
                : .traveling

            if now >= chainEnd {
                guard state.phase != .traveling || state.enforcement != .none else {
                    return nil
                }
                state.phase = .traveling
                state.enforcement = .none
                state.phaseStartedAt = now
                state.lastTransitionReason = .travelChainEnded
                state.revision &+= 1
                return .changed
            }

            guard desiredPhase != state.phase else { return nil }
            state.phase = desiredPhase
            state.enforcement = .none
            state.phaseStartedAt = now
            state.lastTransitionReason = desiredPhase == .offsiteMeeting
                ? .offsiteMeetingStarted
                : .offsiteMeetingEnded
            state.revision &+= 1
            return .changed
        }

        if now >= chainStart {
            beginTravel(at: now, chain: chain)
            return .changed
        }

        let warningStartsAt = chainStart.addingTimeInterval(-BreakTravelPlanner.warningDuration)
        guard state.phase == .focusing,
              now >= warningStartsAt,
              state.enforcement != .required,
              state.enforcement != .travelWarning
        else { return nil }
        state.enforcement = .travelWarning
        state.lastTransitionReason = .travelWarningStarted
        state.revision &+= 1
        return .changed
    }

    private mutating func beginTravel(
        at now: Date,
        chain: [BreakCalendarConstraint]
    ) {
        state.phase = .traveling
        state.enforcement = .travelRequired
        state.phaseStartedAt = now
        state.nominalFocusDueAt = nil
        state.focusDueAt = nil
        state.minimumBreakEndsAt = nil
        state.breakPlanReason = nil
        state.calendarMeetingStartsAt = nil
        state.calendarMeetingEndsAt = nil
        state.scheduledMeetingStartedAt = nil
        state.liveCallStartedAt = nil
        state.liveCallBundleIdentifier = nil
        state.liveCallConfidence = nil
        state.manualMeetingStartedAt = nil
        state.awayPreviousFocusStartedAt = nil
        state.awayReturnDetectedAt = nil
        state.travelChain = chain
        state.lastTransitionReason = .travelStarted
        state.revision &+= 1
    }
}
