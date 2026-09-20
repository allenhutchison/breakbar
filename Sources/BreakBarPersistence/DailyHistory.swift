import Foundation

public enum ActivityKind: String, CaseIterable, Codable, Equatable, Sendable {
    case focus
    case meeting
    case breakTime = "break"
    case lunch
    case travel
    case away
}

public struct WorkSessionHistory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let correctedFromStartedAt: Date?
    public let correctedFromEndedAt: Date?
    public let updatedAt: Date

    public var wasCorrected: Bool {
        correctedFromStartedAt != nil || correctedFromEndedAt != nil
    }

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        correctedFromStartedAt: Date?,
        correctedFromEndedAt: Date?,
        updatedAt: Date
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.correctedFromStartedAt = correctedFromStartedAt
        self.correctedFromEndedAt = correctedFromEndedAt
        self.updatedAt = updatedAt
    }
}

public struct ActivityHistoryInterval: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let kind: ActivityKind
    public let startedAt: Date
    public let endedAt: Date?
    public let source: String
    public let correctedFromKind: ActivityKind?
    public let updatedAt: Date

    public var wasCorrected: Bool { correctedFromKind != nil }

    public init(
        id: String,
        sessionID: String,
        kind: ActivityKind,
        startedAt: Date,
        endedAt: Date?,
        source: String,
        correctedFromKind: ActivityKind?,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.correctedFromKind = correctedFromKind
        self.updatedAt = updatedAt
    }
}

public struct HistoryArchive: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let dateEncoding: String
    public let exportedAt: Date
    public let sessions: [WorkSessionHistory]
    public let intervals: [ActivityHistoryInterval]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        exportedAt: Date,
        sessions: [WorkSessionHistory],
        intervals: [ActivityHistoryInterval]
    ) {
        self.formatVersion = formatVersion
        dateEncoding = "secondsSince1970"
        self.exportedAt = exportedAt
        self.sessions = sessions
        self.intervals = intervals
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

    public func contains(_ date: Date) -> Bool {
        day.start <= date && date < day.end
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
