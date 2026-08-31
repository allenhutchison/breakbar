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

        case .returnToFocus:
            guard state.phase == .onBreak else { return .unchanged }
            let remaining = max(0, (state.minimumBreakEndsAt ?? now).timeIntervalSince(now))
            guard remaining <= 0 else { return .rejected(remaining: remaining) }
            beginFocus(at: now, reason: .returnToFocus)
            return .changed

        case .tick, .reconcile:
            return updateEnforcement(
                at: now,
                reason: command == .tick ? .timerDeadline : .lifecycleReconciliation
            )
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
        state.focusDueAt = nil
        state.minimumBreakEndsAt = now.addingTimeInterval(policy.minimumBreakDuration)
        state.lastTransitionReason = reason
        state.revision &+= 1
        return .changed
    }

    private mutating func updateEnforcement(
        at now: Date,
        reason: BreakTransitionReason
    ) -> BreakCommandResult {
        guard state.phase == .focusing, let dueAt = state.focusDueAt else {
            return .unchanged
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
        state.focusDueAt = now.addingTimeInterval(policy.focusDuration)
        state.minimumBreakEndsAt = nil
        state.lastTransitionReason = reason
        state.revision &+= 1
    }

    private func maxEnforcement(
        _ lhs: BreakEnforcement,
        _ rhs: BreakEnforcement
    ) -> BreakEnforcement {
        let rank: [BreakEnforcement: Int] = [.none: 0, .warning: 1, .required: 2]
        return rank[lhs, default: 0] >= rank[rhs, default: 0] ? lhs : rhs
    }
}
