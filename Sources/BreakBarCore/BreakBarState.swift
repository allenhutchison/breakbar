import Foundation

public enum BreakBarPhase: String, Codable, Equatable, Sendable {
    case clockedOut
    case focusing
    case onBreak
    case onLunch
    case awayUnclassified
    case traveling
    case offsiteMeeting
}

public enum BreakEnforcement: String, Codable, Equatable, Sendable {
    case none
    case warning
    case required
    case travelWarning
    case travelRequired
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
    case breakDeferred
    case calendarPlanUpdated
    case scheduledMeetingStarted
    case scheduledMeetingEnded
    case liveCallStarted
    case liveCallEnded
    case startLunch
    case endLunch
    case startManualMeeting
    case endManualMeeting
    case idleThresholdReached
    case userActivityResumed
    case classifyAwayAsLunch
    case classifyAwayAsBreak
    case classifyAwayAsOther
    case classifyAwayAsWork
    case travelPlanUpdated
    case travelWarningStarted
    case travelStarted
    case travelAcknowledged
    case offsiteMeetingStarted
    case offsiteMeetingEnded
    case travelChainEnded
    case returnHome
    case correctClockIn
}

public enum BreakPlanReason: String, Codable, Equatable, Sendable {
    case nominal
    case pulledBeforeMeeting
    case deferredThroughMeeting
    case postMeetingWarning
    case userDeferred
}

public enum AwayClassification: String, Codable, Equatable, Sendable {
    case lunch
    case breakTime
    case otherAway
    case countAsWork
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
    public var scheduledMeetingStartedAt: Date?
    public var liveCallStartedAt: Date?
    public var liveCallBundleIdentifier: String?
    public var liveCallConfidence: BreakCallConfidence?
    public var manualMeetingStartedAt: Date?
    public var awayPreviousFocusStartedAt: Date?
    public var awayReturnDetectedAt: Date?
    public var travelChain: [BreakCalendarConstraint]?
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
        scheduledMeetingStartedAt: Date? = nil,
        liveCallStartedAt: Date? = nil,
        liveCallBundleIdentifier: String? = nil,
        liveCallConfidence: BreakCallConfidence? = nil,
        manualMeetingStartedAt: Date? = nil,
        awayPreviousFocusStartedAt: Date? = nil,
        awayReturnDetectedAt: Date? = nil,
        travelChain: [BreakCalendarConstraint]? = nil,
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
        self.scheduledMeetingStartedAt = scheduledMeetingStartedAt
        self.liveCallStartedAt = liveCallStartedAt
        self.liveCallBundleIdentifier = liveCallBundleIdentifier
        self.liveCallConfidence = liveCallConfidence
        self.manualMeetingStartedAt = manualMeetingStartedAt
        self.awayPreviousFocusStartedAt = awayPreviousFocusStartedAt
        self.awayReturnDetectedAt = awayReturnDetectedAt
        self.travelChain = travelChain
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
    case idleThresholdReached(idleStartedAt: Date)
    case userActivityResumed
    case classifyAway(AwayClassification)
    case tick
    case reconcile
    case emergencyStartBreak
    case emergencyClockOut
    case deferBreak(by: TimeInterval)
    case updateCalendarConstraints([BreakCalendarConstraint])
    case updateCallActivity(BreakCallSignal?)
    case acknowledgeTravel
    case returnHome
    case correctClockIn(
        from: Date,
        to: Date,
        adjustsCurrentFocusCycle: Bool
    )
}

public enum BreakCommandResult: Equatable, Sendable {
    case changed
    case unchanged
    case rejected(remaining: TimeInterval)
}
