import Foundation

public enum ActivityKind: String, CaseIterable, Equatable, Sendable {
    case focus
    case meeting
    case breakTime = "break"
    case lunch
    case travel
    case away
}

public struct WorkSessionHistory: Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?

    public init(id: String, startedAt: Date, endedAt: Date?) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct ActivityHistoryInterval: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let kind: ActivityKind
    public let startedAt: Date
    public let endedAt: Date?
    public let source: String

    public init(
        id: String,
        sessionID: String,
        kind: ActivityKind,
        startedAt: Date,
        endedAt: Date?,
        source: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
    }
}

public struct DailyHistorySummary: Equatable, Sendable {
    public let clockedIn: TimeInterval
    public let focus: TimeInterval
    public let meetings: TimeInterval
    public let breaks: TimeInterval
    public let lunch: TimeInterval
    public let travel: TimeInterval
    public let away: TimeInterval

    public var working: TimeInterval { focus + meetings }
}

public struct DailyHistory: Equatable, Sendable {
    public let day: DateInterval
    public let sessions: [WorkSessionHistory]
    public let intervals: [ActivityHistoryInterval]

    public init(
        day: DateInterval,
        sessions: [WorkSessionHistory],
        intervals: [ActivityHistoryInterval]
    ) {
        self.day = day
        self.sessions = sessions
        self.intervals = intervals
    }

    public func summary(at now: Date) -> DailyHistorySummary {
        let clockedIn = sessions.reduce(0) { total, session in
            total + duration(
                from: session.startedAt,
                to: session.endedAt,
                at: now
            )
        }

        var totals: [ActivityKind: TimeInterval] = [:]
        for interval in intervals {
            totals[interval.kind, default: 0] += duration(
                from: interval.startedAt,
                to: interval.endedAt,
                at: now
            )
        }

        return DailyHistorySummary(
            clockedIn: clockedIn,
            focus: totals[.focus, default: 0],
            meetings: totals[.meeting, default: 0],
            breaks: totals[.breakTime, default: 0],
            lunch: totals[.lunch, default: 0],
            travel: totals[.travel, default: 0],
            away: totals[.away, default: 0]
        )
    }

    public func clippedStart(for interval: ActivityHistoryInterval) -> Date {
        max(day.start, interval.startedAt)
    }

    public func clippedEnd(for interval: ActivityHistoryInterval, at now: Date) -> Date {
        min(day.end, interval.endedAt ?? now)
    }

    private func duration(from start: Date, to end: Date?, at now: Date) -> TimeInterval {
        let clippedStart = max(day.start, start)
        let clippedEnd = min(day.end, end ?? now)
        return max(0, clippedEnd.timeIntervalSince(clippedStart))
    }
}
