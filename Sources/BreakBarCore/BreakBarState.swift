import Foundation

public enum BreakBarPhase: String, Codable, Equatable, Sendable {
    case clockedOut
    case focusing
    case onBreak
}

public enum BreakEnforcement: String, Codable, Equatable, Sendable {
    case none
    case warning
    case required
}

public enum BreakTransitionReason: String, Codable, Equatable, Sendable {
    case clockIn
    case clockOut
    case startBreak
    case returnToFocus
    case timerDeadline
    case lifecycleReconciliation
    case emergencyStartBreak
    case emergencyClockOut
}

public struct BreakBarState: Codable, Equatable, Sendable {
    public var phase: BreakBarPhase
    public var enforcement: BreakEnforcement
    public var phaseStartedAt: Date?
    public var focusDueAt: Date?
    public var minimumBreakEndsAt: Date?
    public var lastTransitionReason: BreakTransitionReason?
    public var revision: UInt64

    public init(
        phase: BreakBarPhase = .clockedOut,
        enforcement: BreakEnforcement = .none,
        phaseStartedAt: Date? = nil,
        focusDueAt: Date? = nil,
        minimumBreakEndsAt: Date? = nil,
        lastTransitionReason: BreakTransitionReason? = nil,
        revision: UInt64 = 0
    ) {
        self.phase = phase
        self.enforcement = enforcement
        self.phaseStartedAt = phaseStartedAt
        self.focusDueAt = focusDueAt
        self.minimumBreakEndsAt = minimumBreakEndsAt
        self.lastTransitionReason = lastTransitionReason
        self.revision = revision
    }
}

public enum BreakCommand: Equatable, Sendable {
    case clockIn
    case clockOut
    case startBreak
    case returnToFocus
    case tick
    case reconcile
    case emergencyStartBreak
    case emergencyClockOut
}

public enum BreakCommandResult: Equatable, Sendable {
    case changed
    case unchanged
    case rejected(remaining: TimeInterval)
}
