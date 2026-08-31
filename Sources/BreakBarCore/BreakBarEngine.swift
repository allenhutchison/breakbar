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
            beginFocus(at: now)
            return .changed

        case .clockOut:
            guard state.phase != .clockedOut else { return .unchanged }
            state = BreakBarState(revision: state.revision &+ 1)
            return .changed

        case .startBreak:
            guard state.phase == .focusing else { return .unchanged }
            state.phase = .onBreak
            state.enforcement = .none
            state.phaseStartedAt = now
            state.focusDueAt = nil
            state.minimumBreakEndsAt = now.addingTimeInterval(policy.minimumBreakDuration)
            state.revision &+= 1
            return .changed

        case .returnToFocus:
            guard state.phase == .onBreak else { return .unchanged }
            let remaining = max(0, (state.minimumBreakEndsAt ?? now).timeIntervalSince(now))
            guard remaining <= 0 else { return .rejected(remaining: remaining) }
            beginFocus(at: now)
            return .changed

        case .tick:
            guard state.phase == .focusing, let dueAt = state.focusDueAt else {
                return .unchanged
            }
            let nextEnforcement: BreakEnforcement
            if now >= dueAt {
                nextEnforcement = .required
            } else if now >= dueAt.addingTimeInterval(-policy.warningDuration) {
                nextEnforcement = .warning
            } else {
                nextEnforcement = .none
            }
            guard nextEnforcement != state.enforcement else { return .unchanged }
            state.enforcement = nextEnforcement
            state.revision &+= 1
            return .changed
        }
    }

    private mutating func beginFocus(at now: Date) {
        state.phase = .focusing
        state.enforcement = .none
        state.phaseStartedAt = now
        state.focusDueAt = now.addingTimeInterval(policy.focusDuration)
        state.minimumBreakEndsAt = nil
        state.revision &+= 1
    }
}
