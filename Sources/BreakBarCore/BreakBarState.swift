import Foundation

public enum BreakBarPhase: String, Codable, Equatable, Sendable {
    case clockedOut
    case focusing
    case onBreak
    case onLunch
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
    case calendarPlanUpdated
    case scheduledMeetingStarted
    case scheduledMeetingEnded
    case liveCallStarted
    case liveCallEnded
    case startLunch
    case endLunch
    case startManualMeeting
    case endManualMeeting
}

public enum BreakPlanReason: String, Codable, Equatable, Sendable {
    case nominal
    case pulledBeforeMeeting
    case deferredThroughMeeting
    case postMeetingWarning
}

public struct BreakBarState: Codable, Equatable, Sendable {
    public var phase: BreakBarPhase
    public var enforcement: BreakEnforcement
    public var phaseStartedAt: Date?
    public var nominalFocusDueAt: Date?
    public var focusDueAt: Date?
    public var minimumBreakEndsAt: Date?
    public var breakPlanReason: BreakPlanReason?
    public var calendarMeetingStartsAt: Date?
    public var calendarMeetingEndsAt: Date?
    public var liveCallStartedAt: Date?
    public var liveCallBundleIdentifier: String?
    public var liveCallConfidence: BreakCallConfidence?
    public var manualMeetingStartedAt: Date?
    public var lastTransitionReason: BreakTransitionReason?
    public var revision: UInt64

    public init(
        phase: BreakBarPhase = .clockedOut,
        enforcement: BreakEnforcement = .none,
        phaseStartedAt: Date? = nil,
        nominalFocusDueAt: Date? = nil,
        focusDueAt: Date? = nil,
        minimumBreakEndsAt: Date? = nil,
        breakPlanReason: BreakPlanReason? = nil,
        calendarMeetingStartsAt: Date? = nil,
        calendarMeetingEndsAt: Date? = nil,
        liveCallStartedAt: Date? = nil,
        liveCallBundleIdentifier: String? = nil,
        liveCallConfidence: BreakCallConfidence? = nil,
        manualMeetingStartedAt: Date? = nil,
        lastTransitionReason: BreakTransitionReason? = nil,
        revision: UInt64 = 0
    ) {
        self.phase = phase
        self.enforcement = enforcement
        self.phaseStartedAt = phaseStartedAt
        self.nominalFocusDueAt = nominalFocusDueAt
        self.focusDueAt = focusDueAt
        self.minimumBreakEndsAt = minimumBreakEndsAt
        self.breakPlanReason = breakPlanReason
        self.calendarMeetingStartsAt = calendarMeetingStartsAt
        self.calendarMeetingEndsAt = calendarMeetingEndsAt
        self.liveCallStartedAt = liveCallStartedAt
        self.liveCallBundleIdentifier = liveCallBundleIdentifier
        self.liveCallConfidence = liveCallConfidence
        self.manualMeetingStartedAt = manualMeetingStartedAt
        self.lastTransitionReason = lastTransitionReason
        self.revision = revision
    }
}

public enum BreakCommand: Equatable, Sendable {
    case clockIn
    case clockOut
    case startBreak
    case returnToFocus
    case startLunch
    case endLunch
    case startManualMeeting
    case endManualMeeting
    case tick
    case reconcile
    case emergencyStartBreak
    case emergencyClockOut
    case updateCalendarConstraints([BreakCalendarConstraint])
    case updateCallActivity(BreakCallSignal?)
}

public enum BreakCommandResult: Equatable, Sendable {
    case changed
    case unchanged
    case rejected(remaining: TimeInterval)
}
