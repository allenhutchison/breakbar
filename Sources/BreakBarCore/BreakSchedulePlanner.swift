import Foundation

public struct BreakCalendarConstraint: Equatable, Sendable {
    public let id: String
    public let startAt: Date
    public let endAt: Date

    public init(id: String, startAt: Date, endAt: Date) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
    }
}

public struct BreakSchedulePlan: Equatable, Sendable {
    public let nominalBreakAt: Date
    public let plannedBreakAt: Date
    public let reason: BreakPlanReason
    public let meetingStartsAt: Date?
    public let meetingEndsAt: Date?

    public init(
        nominalBreakAt: Date,
        plannedBreakAt: Date,
        reason: BreakPlanReason,
        meetingStartsAt: Date?,
        meetingEndsAt: Date?
    ) {
        self.nominalBreakAt = nominalBreakAt
        self.plannedBreakAt = plannedBreakAt
        self.reason = reason
        self.meetingStartsAt = meetingStartsAt
        self.meetingEndsAt = meetingEndsAt
    }

    public func meetingIsActive(at date: Date) -> Bool {
        guard let meetingStartsAt, let meetingEndsAt else { return false }
        return meetingStartsAt <= date && date < meetingEndsAt
    }
}

public enum BreakSchedulePlanner {
    public static func plan(
        cycleStartedAt: Date,
        now: Date,
        policy: BreakPolicy,
        constraints: [BreakCalendarConstraint]
    ) -> BreakSchedulePlan {
        let nominalBreakAt = cycleStartedAt.addingTimeInterval(policy.focusDuration)
        let meetings = constraints
            .filter { $0.endAt > now && $0.endAt > $0.startAt }
            .sorted { $0.startAt < $1.startAt }

        if let activeMeeting = meetings.first(where: {
            $0.startAt <= now && now < $0.endAt
        }) {
            let breakIsDue = now >= nominalBreakAt
            return BreakSchedulePlan(
                nominalBreakAt: nominalBreakAt,
                plannedBreakAt: breakIsDue
                    ? activeMeeting.endAt.addingTimeInterval(policy.warningDuration)
                    : nominalBreakAt,
                reason: breakIsDue ? .deferredThroughMeeting : .nominal,
                meetingStartsAt: activeMeeting.startAt,
                meetingEndsAt: activeMeeting.endAt
            )
        }

        for meeting in meetings where meetingConflicts(
            meeting,
            nominalBreakAt: nominalBreakAt,
            policy: policy
        ) {
            let preMeetingBreakAt = meeting.startAt.addingTimeInterval(-policy.minimumBreakDuration)
            let warningStartsAt = preMeetingBreakAt.addingTimeInterval(-policy.warningDuration)
            let warningAndBreakFit = warningStartsAt >= now
                && preMeetingBreakAt <= nominalBreakAt
                && !meetings.contains {
                    $0.id != meeting.id
                        && intervalsOverlap(
                            warningStartsAt,
                            meeting.startAt,
                            $0.startAt,
                            $0.endAt
                        )
                }

            if warningAndBreakFit {
                return BreakSchedulePlan(
                    nominalBreakAt: nominalBreakAt,
                    plannedBreakAt: preMeetingBreakAt,
                    reason: .pulledBeforeMeeting,
                    meetingStartsAt: meeting.startAt,
                    meetingEndsAt: meeting.endAt
                )
            }

            return BreakSchedulePlan(
                nominalBreakAt: nominalBreakAt,
                plannedBreakAt: meeting.endAt.addingTimeInterval(policy.warningDuration),
                reason: .deferredThroughMeeting,
                meetingStartsAt: meeting.startAt,
                meetingEndsAt: meeting.endAt
            )
        }

        return BreakSchedulePlan(
            nominalBreakAt: nominalBreakAt,
            plannedBreakAt: nominalBreakAt,
            reason: .nominal,
            meetingStartsAt: nil,
            meetingEndsAt: nil
        )
    }

    private static func meetingConflicts(
        _ meeting: BreakCalendarConstraint,
        nominalBreakAt: Date,
        policy: BreakPolicy
    ) -> Bool {
        let nominalBreakEndsAt = nominalBreakAt.addingTimeInterval(policy.minimumBreakDuration)
        return meeting.startAt < nominalBreakEndsAt
            && meeting.endAt > nominalBreakAt
    }

    private static func intervalsOverlap(
        _ lhsStart: Date,
        _ lhsEnd: Date,
        _ rhsStart: Date,
        _ rhsEnd: Date
    ) -> Bool {
        lhsStart < rhsEnd && rhsStart < lhsEnd
    }
}
