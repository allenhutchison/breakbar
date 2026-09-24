import BreakBarCore
import CSQLite
import Foundation

public enum SessionRepositoryError: Error, LocalizedError, Equatable {
    case couldNotOpen(String)
    case sqlite(String)
    case staleState
    case missingOpenSession
    case missingOpenInterval
    case intervalNotFound
    case cannotCorrectOpenInterval
    case invalidCorrectionRange
    case correctionOutsideSession
    case correctionOverlapsExistingInterval
    case sessionNotFound
    case cannotCorrectOpenSession
    case sessionIsNotOpen
    case invalidSessionCorrectionRange
    case sessionCorrectionEndsInFuture
    case invalidActiveSessionStart
    case sessionCorrectionWouldInvalidateIntervals
    case sessionCorrectionOverlapsExistingSession
    case travelCorrectionRequiresReturnedFocus
    case travelCorrectionOutsideTravelInterval
    case historyDeletionRequiresClockedOut
    case unsupportedTransition(from: BreakBarPhase, to: BreakBarPhase)

    public var errorDescription: String? {
        switch self {
        case let .couldNotOpen(message), let .sqlite(message): message
        case .staleState: "The saved state changed before this transition could be committed."
        case .missingOpenSession: "The active timer has no open work session."
        case .missingOpenInterval: "The active timer has no open activity interval."
        case .intervalNotFound: "That activity interval no longer exists."
        case .cannotCorrectOpenInterval: "The current activity cannot be edited until it ends."
        case .invalidCorrectionRange: "The end time must be later than the start time."
        case .correctionOutsideSession: "The activity must remain within its clocked-in session."
        case .correctionOverlapsExistingInterval: "That time overlaps another activity."
        case .sessionNotFound: "That work session no longer exists."
        case .cannotCorrectOpenSession: "Clock-in and clock-out times can be edited after clocking out."
        case .sessionIsNotOpen: "That work session is no longer active."
        case .invalidSessionCorrectionRange: "The clock-out time must be later than the clock-in time."
        case .sessionCorrectionEndsInFuture: "The clock-out time cannot be later than the current time."
        case .invalidActiveSessionStart: "The clock-in time must be earlier than the current time."
        case .sessionCorrectionWouldInvalidateIntervals:
            "Those times would exclude activity already recorded in this work session."
        case .sessionCorrectionOverlapsExistingSession: "Those times overlap another work session."
        case .travelCorrectionRequiresReturnedFocus:
            "This travel interval must lead directly to a resumed focus session."
        case .travelCorrectionOutsideTravelInterval:
            "The clock-out time must fall within the travel interval."
        case .historyDeletionRequiresClockedOut:
            "Clock out before deleting local history."
        case let .unsupportedTransition(from, to):
            "Unsupported timer transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}

public enum HistoryDeletionResult: Equatable, Sendable {
    case deleted
    case deletedWithCleanupWarning(String)
}

public struct SessionRepositoryStats: Equatable, Sendable {
    public let totalSessions: Int
    public let openSessions: Int
    public let totalIntervals: Int
    public let openIntervals: Int
    public let focusIntervals: Int
    public let breakIntervals: Int
    public let lunchIntervals: Int
    public let awayIntervals: Int
    public let travelIntervals: Int
    public let meetingIntervals: Int

    public init(
        totalSessions: Int,
        openSessions: Int,
        totalIntervals: Int,
        openIntervals: Int,
        focusIntervals: Int,
        breakIntervals: Int,
        lunchIntervals: Int = 0,
        awayIntervals: Int = 0,
        travelIntervals: Int = 0,
        meetingIntervals: Int = 0
    ) {
        self.totalSessions = totalSessions
        self.openSessions = openSessions
        self.totalIntervals = totalIntervals
        self.openIntervals = openIntervals
        self.focusIntervals = focusIntervals
        self.breakIntervals = breakIntervals
        self.lunchIntervals = lunchIntervals
        self.awayIntervals = awayIntervals
        self.travelIntervals = travelIntervals
        self.meetingIntervals = meetingIntervals
    }
}

public final class SessionRepository {
    public static let schemaVersion = 6

    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK,
              let connection
        else {
            let message = connection.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "Unknown SQLite open error"
            if let connection { sqlite3_close(connection) }
            throw SessionRepositoryError.couldNotOpen(message)
        }
        database = connection

        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA busy_timeout = 3000")
            try execute("PRAGMA secure_delete = ON")
            try migrate()
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func bootstrapIfNeeded(state: BreakBarState, at now: Date = Date()) throws {
        guard try loadState() == nil else { return }

        try transaction {
            if state.phase != .clockedOut {
                let sessionID = UUID().uuidString
                let startedAt = state.phaseStartedAt ?? now
                try insertSession(id: sessionID, startedAt: startedAt)
                try insertInterval(
                    sessionID: sessionID,
                    phase: state.phase,
                    startedAt: startedAt,
                    minimumSatisfiedAt: state.minimumBreakEndsAt
                )
            }
            try saveSnapshot(state)
        }
    }

    public func loadState() throws -> BreakBarState? {
        let data: Data? = try queryOne(
            "SELECT payload FROM state_snapshot WHERE singleton_id = 1"
        ) { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        guard let data else { return nil }
        do {
            return try decoder.decode(BreakBarState.self, from: data)
        } catch {
            throw SessionRepositoryError.sqlite("Could not decode the saved timer state: \(error.localizedDescription)")
        }
    }

    public func isHealthy() throws -> Bool {
        let result: String? = try queryOne("PRAGMA quick_check") { statement in
            String(cString: sqlite3_column_text(statement, 0))
        }
        return result == "ok"
    }

    public func commitTransition(
        from previous: BreakBarState,
        to next: BreakBarState,
        at date: Date
    ) throws {
        try transaction {
            guard try loadState() == previous else {
                throw SessionRepositoryError.staleState
            }

            switch (previous.phase, next.phase) {
            case (.clockedOut, .focusing):
                let sessionID = UUID().uuidString
                try insertSession(id: sessionID, startedAt: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .focusing,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.focusing, .onBreak):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .onBreak,
                    startedAt: date,
                    minimumSatisfiedAt: next.minimumBreakEndsAt
                )

            case (.onBreak, .focusing):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .focusing,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.focusing, .onLunch):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .onLunch,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.onLunch, .focusing):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .focusing,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.focusing, .awayUnclassified):
                let sessionID = try openSessionID()
                let awayStartedAt = next.phaseStartedAt ?? date
                try closeOpenInterval(at: awayStartedAt)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .awayUnclassified,
                    startedAt: awayStartedAt,
                    minimumSatisfiedAt: nil
                )

            case (.awayUnclassified, .focusing):
                let sessionID = try openSessionID()
                let returnedAt = next.phaseStartedAt
                    ?? previous.awayReturnDetectedAt
                    ?? date
                switch next.lastTransitionReason {
                case .classifyAwayAsLunch:
                    try resolveOpenAwayInterval(as: "lunch", endedAt: returnedAt)
                    try insertInterval(
                        sessionID: sessionID,
                        phase: .focusing,
                        startedAt: returnedAt,
                        minimumSatisfiedAt: nil
                    )
                case .classifyAwayAsBreak:
                    try resolveOpenAwayInterval(as: "break", endedAt: returnedAt)
                    try insertInterval(
                        sessionID: sessionID,
                        phase: .focusing,
                        startedAt: returnedAt,
                        minimumSatisfiedAt: nil
                    )
                case .classifyAwayAsOther:
                    try closeOpenInterval(at: returnedAt)
                    try insertInterval(
                        sessionID: sessionID,
                        phase: .focusing,
                        startedAt: returnedAt,
                        minimumSatisfiedAt: nil
                    )
                case .classifyAwayAsWork:
                    try restoreFocusAcrossOpenAwayInterval(sessionID: sessionID)
                default:
                    throw SessionRepositoryError.unsupportedTransition(
                        from: previous.phase,
                        to: next.phase
                    )
                }

            case (.focusing, .traveling),
                 (.onBreak, .traveling),
                 (.onLunch, .traveling),
                 (.awayUnclassified, .traveling):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .traveling,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.traveling, .offsiteMeeting),
                 (.offsiteMeeting, .traveling):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: next.phase,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.traveling, .focusing),
                 (.offsiteMeeting, .focusing):
                let sessionID = try openSessionID()
                try closeOpenInterval(at: date)
                try insertInterval(
                    sessionID: sessionID,
                    phase: .focusing,
                    startedAt: date,
                    minimumSatisfiedAt: nil
                )

            case (.focusing, .clockedOut),
                 (.onBreak, .clockedOut),
                 (.onLunch, .clockedOut),
                 (.awayUnclassified, .clockedOut),
                 (.traveling, .clockedOut),
                 (.offsiteMeeting, .clockedOut):
                _ = try openSessionID()
                try closeOpenInterval(at: date)
                try closeOpenSession(at: date)

            case (.focusing, .focusing):
                try reconcileMeetingInterval(from: previous, to: next, at: date)

            case (.onBreak, .onBreak),
                 (.onLunch, .onLunch),
                 (.awayUnclassified, .awayUnclassified),
                 (.traveling, .traveling),
                 (.offsiteMeeting, .offsiteMeeting),
                 (.clockedOut, .clockedOut):
                break

            default:
                throw SessionRepositoryError.unsupportedTransition(
                    from: previous.phase,
                    to: next.phase
                )
            }

            try saveSnapshot(next)
        }
    }

    public func stats() throws -> SessionRepositoryStats {
        SessionRepositoryStats(
            totalSessions: try count("SELECT COUNT(*) FROM work_sessions"),
            openSessions: try count("SELECT COUNT(*) FROM work_sessions WHERE ended_at_utc IS NULL"),
            totalIntervals: try count("SELECT COUNT(*) FROM intervals"),
            openIntervals: try count("SELECT COUNT(*) FROM intervals WHERE ended_at_utc IS NULL"),
            focusIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'focus'"),
            breakIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'break'"),
            lunchIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'lunch'"),
            awayIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'away'"),
            travelIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'travel'"),
            meetingIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'meeting'")
        )
    }

    public func completeHistory(exportedAt: Date = Date()) throws -> HistoryArchive {
        let sessions: [WorkSessionHistory] = try withStatement(
            """
            SELECT id, started_at_utc, ended_at_utc,
                   corrected_from_started_at_utc, corrected_from_ended_at_utc,
                   updated_at_utc
            FROM work_sessions
            ORDER BY started_at_utc, id
            """
        ) { statement in
            var rows: [WorkSessionHistory] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                rows.append(workSessionHistory(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return rows
        }

        let intervals: [ActivityHistoryInterval] = try withStatement(
            """
            SELECT id, session_id, kind, started_at_utc, ended_at_utc, source,
                   corrected_from_kind, updated_at_utc
            FROM intervals
            ORDER BY started_at_utc, id
            """
        ) { statement in
            var rows: [ActivityHistoryInterval] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                rows.append(try activityHistoryInterval(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return rows
        }

        return HistoryArchive(
            exportedAt: exportedAt,
            sessions: sessions,
            intervals: intervals
        )
    }

    public func deleteAllHistory(
        expectedState: BreakBarState
    ) throws -> HistoryDeletionResult {
        guard expectedState.phase == .clockedOut else {
            throw SessionRepositoryError.historyDeletionRequiresClockedOut
        }

        try transaction {
            guard try loadState() == expectedState else {
                throw SessionRepositoryError.staleState
            }
            try execute("DELETE FROM work_sessions")
        }

        do {
            try checkpointAndTruncateWAL()
            try execute("VACUUM")
            try checkpointAndTruncateWAL()
            return .deleted
        } catch {
            return .deletedWithCleanupWarning(error.localizedDescription)
        }
    }

    public func dailyHistory(
        on date: Date,
        calendar: Calendar = .current
    ) throws -> DailyHistory {
        guard let day = calendar.dateInterval(of: .day, for: date) else {
            throw SessionRepositoryError.sqlite("Could not determine the selected calendar day.")
        }

        let sessions: [WorkSessionHistory] = try withStatement(
            """
            SELECT id, started_at_utc, ended_at_utc,
                   corrected_from_started_at_utc, corrected_from_ended_at_utc,
                   updated_at_utc
            FROM work_sessions
            WHERE started_at_utc < ?
              AND (ended_at_utc IS NULL OR ended_at_utc > ?)
            ORDER BY started_at_utc, id
            """
        ) { statement in
            try bind(day.end, to: statement, at: 1)
            try bind(day.start, to: statement, at: 2)
            var rows: [WorkSessionHistory] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                rows.append(workSessionHistory(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return rows
        }

        let intervals: [ActivityHistoryInterval] = try withStatement(
            """
            SELECT id, session_id, kind, started_at_utc, ended_at_utc, source,
                   corrected_from_kind, updated_at_utc
            FROM intervals
            WHERE started_at_utc < ?
              AND (ended_at_utc IS NULL OR ended_at_utc > ?)
            ORDER BY started_at_utc, id
            """
        ) { statement in
            try bind(day.end, to: statement, at: 1)
            try bind(day.start, to: statement, at: 2)
            var rows: [ActivityHistoryInterval] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                rows.append(try activityHistoryInterval(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return rows
        }

        return DailyHistory(day: day, sessions: sessions, intervals: intervals)
    }

    public func correctInterval(
        id: String,
        kind: ActivityKind,
        startedAt: Date,
        endedAt: Date,
        correctedAt: Date = Date()
    ) throws {
        guard startedAt < endedAt else {
            throw SessionRepositoryError.invalidCorrectionRange
        }

        try transaction {
            let existing: (
                sessionID: String,
                kind: ActivityKind,
                endedAt: Date?,
                correctedFromKind: ActivityKind?,
                sessionStartedAt: Date,
                sessionEndedAt: Date?
            )? = try withStatement(
                """
                SELECT i.session_id, i.kind, i.ended_at_utc, i.corrected_from_kind,
                       s.started_at_utc, s.ended_at_utc
                FROM intervals i
                JOIN work_sessions s ON s.id = i.session_id
                WHERE i.id = ?
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result != SQLITE_DONE else { return nil }
                guard result == SQLITE_ROW else { throw lastError() }
                let rawKind = String(cString: sqlite3_column_text(statement, 1))
                guard let existingKind = ActivityKind(rawValue: rawKind) else {
                    throw SessionRepositoryError.sqlite("Unknown activity kind: \(rawKind)")
                }
                let correctedFromKind: ActivityKind?
                if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                    correctedFromKind = nil
                } else {
                    let rawCorrectedKind = String(cString: sqlite3_column_text(statement, 3))
                    guard let parsedKind = ActivityKind(rawValue: rawCorrectedKind) else {
                        throw SessionRepositoryError.sqlite(
                            "Unknown original activity kind: \(rawCorrectedKind)"
                        )
                    }
                    correctedFromKind = parsedKind
                }
                return (
                    String(cString: sqlite3_column_text(statement, 0)),
                    existingKind,
                    optionalDate(in: statement, at: 2),
                    correctedFromKind,
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    optionalDate(in: statement, at: 5)
                )
            }

            guard let existing else { throw SessionRepositoryError.intervalNotFound }
            guard existing.endedAt != nil else {
                throw SessionRepositoryError.cannotCorrectOpenInterval
            }
            guard startedAt >= existing.sessionStartedAt,
                  existing.sessionEndedAt.map({ endedAt <= $0 }) ?? true
            else {
                throw SessionRepositoryError.correctionOutsideSession
            }

            let overlappingCount: Int = try withStatement(
                """
                SELECT COUNT(*)
                FROM intervals
                WHERE session_id = ?
                  AND id <> ?
                  AND started_at_utc < ?
                  AND (ended_at_utc IS NULL OR ended_at_utc > ?)
                """
            ) { statement in
                try bind(existing.sessionID, to: statement, at: 1)
                try bind(id, to: statement, at: 2)
                try bind(endedAt, to: statement, at: 3)
                try bind(startedAt, to: statement, at: 4)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            guard overlappingCount == 0 else {
                throw SessionRepositoryError.correctionOverlapsExistingInterval
            }

            let originalKind = existing.correctedFromKind ?? existing.kind
            try withStatement(
                """
                UPDATE intervals
                SET kind = ?, started_at_utc = ?, ended_at_utc = ?,
                    corrected_from_kind = ?, updated_at_utc = ?
                WHERE id = ?
                """
            ) { statement in
                try bind(kind.rawValue, to: statement, at: 1)
                try bind(startedAt, to: statement, at: 2)
                try bind(endedAt, to: statement, at: 3)
                try bind(originalKind.rawValue, to: statement, at: 4)
                try bind(correctedAt, to: statement, at: 5)
                try bind(id, to: statement, at: 6)
                try stepDone(statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SessionRepositoryError.intervalNotFound
            }
        }
    }

    public func correctWorkSession(
        id: String,
        startedAt: Date,
        endedAt: Date,
        correctedAt: Date = Date()
    ) throws {
        guard startedAt < endedAt else {
            throw SessionRepositoryError.invalidSessionCorrectionRange
        }
        guard endedAt <= correctedAt else {
            throw SessionRepositoryError.sessionCorrectionEndsInFuture
        }

        try transaction {
            let existing: (
                startedAt: Date,
                endedAt: Date?,
                correctedFromStartedAt: Date?,
                correctedFromEndedAt: Date?
            )? = try withStatement(
                """
                SELECT started_at_utc, ended_at_utc,
                       corrected_from_started_at_utc, corrected_from_ended_at_utc
                FROM work_sessions
                WHERE id = ?
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result != SQLITE_DONE else { return nil }
                guard result == SQLITE_ROW else { throw lastError() }
                return (
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    optionalDate(in: statement, at: 1),
                    optionalDate(in: statement, at: 2),
                    optionalDate(in: statement, at: 3)
                )
            }

            guard let existing else { throw SessionRepositoryError.sessionNotFound }
            guard let existingEndedAt = existing.endedAt else {
                throw SessionRepositoryError.cannotCorrectOpenSession
            }

            let firstInterval: (id: String, endedAt: Date?)? = try withStatement(
                """
                SELECT id, ended_at_utc
                FROM intervals
                WHERE session_id = ?
                ORDER BY started_at_utc, id
                LIMIT 1
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result != SQLITE_DONE else { return nil }
                guard result == SQLITE_ROW else { throw lastError() }
                return (
                    String(cString: sqlite3_column_text(statement, 0)),
                    optionalDate(in: statement, at: 1)
                )
            }
            let lastInterval: (id: String, startedAt: Date)? = try withStatement(
                """
                SELECT id, started_at_utc
                FROM intervals
                WHERE session_id = ?
                ORDER BY started_at_utc DESC, id DESC
                LIMIT 1
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result != SQLITE_DONE else { return nil }
                guard result == SQLITE_ROW else { throw lastError() }
                return (
                    String(cString: sqlite3_column_text(statement, 0)),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                )
            }
            guard let firstInterval,
                  let firstIntervalEndedAt = firstInterval.endedAt,
                  let lastInterval
            else {
                throw SessionRepositoryError.sessionCorrectionWouldInvalidateIntervals
            }
            if firstInterval.id != lastInterval.id {
                guard startedAt < firstIntervalEndedAt,
                      endedAt > lastInterval.startedAt
                else {
                    throw SessionRepositoryError.sessionCorrectionWouldInvalidateIntervals
                }
            }

            let overlappingCount: Int = try withStatement(
                """
                SELECT COUNT(*)
                FROM work_sessions
                WHERE id <> ?
                  AND started_at_utc < ?
                  AND (ended_at_utc IS NULL OR ended_at_utc > ?)
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                try bind(endedAt, to: statement, at: 2)
                try bind(startedAt, to: statement, at: 3)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            guard overlappingCount == 0 else {
                throw SessionRepositoryError.sessionCorrectionOverlapsExistingSession
            }

            let originalStartedAt = existing.correctedFromStartedAt ?? existing.startedAt
            let originalEndedAt = existing.correctedFromEndedAt ?? existingEndedAt
            try withStatement(
                """
                UPDATE work_sessions
                SET started_at_utc = ?, ended_at_utc = ?,
                    corrected_from_started_at_utc = ?, corrected_from_ended_at_utc = ?,
                    updated_at_utc = ?
                WHERE id = ?
                """
            ) { statement in
                try bind(startedAt, to: statement, at: 1)
                try bind(endedAt, to: statement, at: 2)
                try bind(originalStartedAt, to: statement, at: 3)
                try bind(originalEndedAt, to: statement, at: 4)
                try bind(correctedAt, to: statement, at: 5)
                try bind(id, to: statement, at: 6)
                try stepDone(statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SessionRepositoryError.sessionNotFound
            }

            if firstInterval.id == lastInterval.id {
                try withStatement(
                    """
                    UPDATE intervals
                    SET started_at_utc = ?, ended_at_utc = ?,
                        corrected_from_kind = COALESCE(corrected_from_kind, kind),
                        updated_at_utc = ?
                    WHERE id = ?
                    """
                ) { statement in
                    try bind(startedAt, to: statement, at: 1)
                    try bind(endedAt, to: statement, at: 2)
                    try bind(correctedAt, to: statement, at: 3)
                    try bind(firstInterval.id, to: statement, at: 4)
                    try stepDone(statement)
                }
            } else {
                try withStatement(
                    """
                    UPDATE intervals
                    SET started_at_utc = ?,
                        corrected_from_kind = COALESCE(corrected_from_kind, kind),
                        updated_at_utc = ?
                    WHERE id = ?
                    """
                ) { statement in
                    try bind(startedAt, to: statement, at: 1)
                    try bind(correctedAt, to: statement, at: 2)
                    try bind(firstInterval.id, to: statement, at: 3)
                    try stepDone(statement)
                }
                try withStatement(
                    """
                    UPDATE intervals
                    SET ended_at_utc = ?,
                        corrected_from_kind = COALESCE(corrected_from_kind, kind),
                        updated_at_utc = ?
                    WHERE id = ?
                    """
                ) { statement in
                    try bind(endedAt, to: statement, at: 1)
                    try bind(correctedAt, to: statement, at: 2)
                    try bind(lastInterval.id, to: statement, at: 3)
                    try stepDone(statement)
                }
            }
        }
    }

    public func clockOutBeforeTravelReturn(
        travelIntervalID: String,
        clockedOutAt: Date,
        expectedState: BreakBarState,
        correctedAt: Date = Date()
    ) throws {
        try transaction {
            guard try loadState() == expectedState else {
                throw SessionRepositoryError.staleState
            }

            let travel: (sessionID: String, startedAt: Date, returnedAt: Date,
                         sessionStartedAt: Date, sessionEndedAt: Date?)? = try withStatement(
                """
                SELECT i.session_id, i.started_at_utc, i.ended_at_utc,
                       s.started_at_utc, s.ended_at_utc
                FROM intervals i
                JOIN work_sessions s ON s.id = i.session_id
                WHERE i.id = ? AND i.kind = 'travel' AND i.ended_at_utc IS NOT NULL
                """
            ) { statement in
                try bind(travelIntervalID, to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return (
                    String(cString: sqlite3_column_text(statement, 0)),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    optionalDate(in: statement, at: 4)
                )
            }
            guard let travel else {
                throw SessionRepositoryError.travelCorrectionRequiresReturnedFocus
            }
            guard travel.sessionEndedAt.map({ $0 > travel.returnedAt }) ?? true else {
                throw SessionRepositoryError.travelCorrectionRequiresReturnedFocus
            }
            guard clockedOutAt > travel.startedAt,
                  clockedOutAt > travel.sessionStartedAt,
                  clockedOutAt < travel.returnedAt,
                  clockedOutAt <= correctedAt
            else {
                throw SessionRepositoryError.travelCorrectionOutsideTravelInterval
            }

            let resumedFocusCount: Int = try withStatement(
                """
                SELECT COUNT(*) FROM intervals
                WHERE session_id = ? AND kind = 'focus' AND started_at_utc = ?
                """
            ) { statement in
                try bind(travel.sessionID, to: statement, at: 1)
                try bind(travel.returnedAt, to: statement, at: 2)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            let laterBoundaryIntervalCount: Int = try withStatement(
                """
                SELECT COUNT(*) FROM intervals
                WHERE session_id = ? AND started_at_utc >= ?
                  AND ((? IS NULL AND ended_at_utc IS NULL) OR ended_at_utc = ?)
                """
            ) { statement in
                try bind(travel.sessionID, to: statement, at: 1)
                try bind(travel.returnedAt, to: statement, at: 2)
                try bind(travel.sessionEndedAt, to: statement, at: 3)
                try bind(travel.sessionEndedAt, to: statement, at: 4)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            guard resumedFocusCount == 1, laterBoundaryIntervalCount == 1 else {
                throw SessionRepositoryError.travelCorrectionRequiresReturnedFocus
            }

            let newSessionID = UUID().uuidString
            try withStatement(
                """
                UPDATE intervals
                SET ended_at_utc = ?,
                    corrected_from_kind = COALESCE(corrected_from_kind, kind),
                    updated_at_utc = ?
                WHERE id = ?
                """
            ) { statement in
                try bind(clockedOutAt, to: statement, at: 1)
                try bind(correctedAt, to: statement, at: 2)
                try bind(travelIntervalID, to: statement, at: 3)
                try stepDone(statement)
            }
            try withStatement(
                """
                UPDATE work_sessions
                SET ended_at_utc = ?, updated_at_utc = ?
                WHERE id = ?
                """
            ) { statement in
                try bind(clockedOutAt, to: statement, at: 1)
                try bind(correctedAt, to: statement, at: 2)
                try bind(travel.sessionID, to: statement, at: 3)
                try stepDone(statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SessionRepositoryError.missingOpenSession
            }
            try withStatement(
                """
                INSERT INTO work_sessions
                    (id, started_at_utc, ended_at_utc, created_at_utc, updated_at_utc)
                VALUES (?, ?, ?, ?, ?)
                """
            ) { statement in
                try bind(newSessionID, to: statement, at: 1)
                try bind(travel.returnedAt, to: statement, at: 2)
                try bind(travel.sessionEndedAt, to: statement, at: 3)
                try bind(correctedAt, to: statement, at: 4)
                try bind(correctedAt, to: statement, at: 5)
                try stepDone(statement)
            }
            try withStatement(
                """
                UPDATE intervals SET session_id = ?, updated_at_utc = ?
                WHERE session_id = ? AND started_at_utc >= ?
                """
            ) { statement in
                try bind(newSessionID, to: statement, at: 1)
                try bind(correctedAt, to: statement, at: 2)
                try bind(travel.sessionID, to: statement, at: 3)
                try bind(travel.returnedAt, to: statement, at: 4)
                try stepDone(statement)
            }
            guard sqlite3_changes(database) > 0 else {
                throw SessionRepositoryError.travelCorrectionRequiresReturnedFocus
            }
        }
    }

    public func correctOpenWorkSessionStart(
        id: String,
        from previous: BreakBarState,
        to next: BreakBarState,
        startedAt: Date,
        correctedAt: Date = Date()
    ) throws {
        guard startedAt < correctedAt else {
            throw SessionRepositoryError.invalidActiveSessionStart
        }

        try transaction {
            guard try loadState() == previous else {
                throw SessionRepositoryError.staleState
            }

            let existing: (
                startedAt: Date,
                endedAt: Date?,
                correctedFromStartedAt: Date?
            )? = try withStatement(
                """
                SELECT started_at_utc, ended_at_utc, corrected_from_started_at_utc
                FROM work_sessions
                WHERE id = ?
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result != SQLITE_DONE else { return nil }
                guard result == SQLITE_ROW else { throw lastError() }
                return (
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    optionalDate(in: statement, at: 1),
                    optionalDate(in: statement, at: 2)
                )
            }
            guard let existing else { throw SessionRepositoryError.sessionNotFound }
            guard existing.endedAt == nil else {
                throw SessionRepositoryError.sessionIsNotOpen
            }

            let firstInterval: (id: String, endedAt: Date?)? = try withStatement(
                """
                SELECT id, ended_at_utc
                FROM intervals
                WHERE session_id = ?
                ORDER BY started_at_utc, id
                LIMIT 1
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result != SQLITE_DONE else { return nil }
                guard result == SQLITE_ROW else { throw lastError() }
                return (
                    String(cString: sqlite3_column_text(statement, 0)),
                    optionalDate(in: statement, at: 1)
                )
            }
            guard let firstInterval,
                  firstInterval.endedAt.map({ startedAt < $0 }) ?? true
            else {
                throw SessionRepositoryError.sessionCorrectionWouldInvalidateIntervals
            }

            let overlappingCount: Int = try withStatement(
                """
                SELECT COUNT(*)
                FROM work_sessions
                WHERE id <> ?
                  AND (ended_at_utc IS NULL OR ended_at_utc > ?)
                """
            ) { statement in
                try bind(id, to: statement, at: 1)
                try bind(startedAt, to: statement, at: 2)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            guard overlappingCount == 0 else {
                throw SessionRepositoryError.sessionCorrectionOverlapsExistingSession
            }

            let originalStartedAt = existing.correctedFromStartedAt ?? existing.startedAt
            try withStatement(
                """
                UPDATE work_sessions
                SET started_at_utc = ?, corrected_from_started_at_utc = ?,
                    updated_at_utc = ?
                WHERE id = ? AND ended_at_utc IS NULL
                """
            ) { statement in
                try bind(startedAt, to: statement, at: 1)
                try bind(originalStartedAt, to: statement, at: 2)
                try bind(correctedAt, to: statement, at: 3)
                try bind(id, to: statement, at: 4)
                try stepDone(statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SessionRepositoryError.sessionIsNotOpen
            }

            try withStatement(
                """
                UPDATE intervals
                SET started_at_utc = ?,
                    corrected_from_kind = COALESCE(corrected_from_kind, kind),
                    updated_at_utc = ?
                WHERE id = ?
                """
            ) { statement in
                try bind(startedAt, to: statement, at: 1)
                try bind(correctedAt, to: statement, at: 2)
                try bind(firstInterval.id, to: statement, at: 3)
                try stepDone(statement)
            }

            try saveSnapshot(next)
        }
    }

    public func isOpenWorkSessionInInitialFocusCycle(id: String) throws -> Bool {
        let result: (endedAt: Date?, intervalCount: Int, openFocusCount: Int)? = try withStatement(
            """
            SELECT work_sessions.ended_at_utc,
                   COUNT(intervals.id),
                   COALESCE(SUM(
                       CASE
                           WHEN intervals.kind = 'focus'
                            AND intervals.ended_at_utc IS NULL THEN 1
                           ELSE 0
                       END
                   ), 0)
            FROM work_sessions
            LEFT JOIN intervals ON intervals.session_id = work_sessions.id
            WHERE work_sessions.id = ?
            GROUP BY work_sessions.id
            """
        ) { statement in
            try bind(id, to: statement, at: 1)
            let step = sqlite3_step(statement)
            guard step != SQLITE_DONE else { return nil }
            guard step == SQLITE_ROW else { throw lastError() }
            return (
                optionalDate(in: statement, at: 0),
                Int(sqlite3_column_int64(statement, 1)),
                Int(sqlite3_column_int64(statement, 2))
            )
        }
        guard let result else { throw SessionRepositoryError.sessionNotFound }
        guard result.endedAt == nil else { throw SessionRepositoryError.sessionIsNotOpen }
        return result.intervalCount == 1 && result.openFocusCount == 1
    }

    private func migrate() throws {
        var version = try count("PRAGMA user_version")
        guard version <= Self.schemaVersion else {
            throw SessionRepositoryError.sqlite(
                "Database schema \(version) is newer than this app supports."
            )
        }
        if version == 0 {
            try transaction {
                try execute(
                    """
                CREATE TABLE work_sessions (
                    id TEXT PRIMARY KEY,
                    started_at_utc REAL NOT NULL,
                    ended_at_utc REAL,
                    created_at_utc REAL NOT NULL,
                    corrected_from_started_at_utc REAL,
                    corrected_from_ended_at_utc REAL,
                    updated_at_utc REAL NOT NULL
                );

                CREATE UNIQUE INDEX one_open_work_session
                ON work_sessions((1)) WHERE ended_at_utc IS NULL;

                CREATE TABLE intervals (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('focus', 'break', 'lunch', 'away', 'travel', 'meeting')),
                    started_at_utc REAL NOT NULL,
                    ended_at_utc REAL,
                    source TEXT NOT NULL,
                    minimum_satisfied_at_utc REAL,
                    created_at_utc REAL NOT NULL,
                    corrected_from_kind TEXT CHECK (
                        corrected_from_kind IS NULL OR
                        corrected_from_kind IN ('focus', 'break', 'lunch', 'away', 'travel', 'meeting')
                    ),
                    updated_at_utc REAL NOT NULL,
                    CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)
                );

                CREATE UNIQUE INDEX one_open_interval
                ON intervals((1)) WHERE ended_at_utc IS NULL;

                CREATE TABLE state_snapshot (
                    singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
                    revision INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    updated_at_utc REAL NOT NULL
                );

                PRAGMA user_version = 6;
                """
                )
            }
            return
        }

        if version == 1 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE intervals_v2 (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL CHECK (kind IN ('focus', 'break', 'lunch')),
                        started_at_utc REAL NOT NULL,
                        ended_at_utc REAL,
                        source TEXT NOT NULL,
                        minimum_satisfied_at_utc REAL,
                        created_at_utc REAL NOT NULL,
                        CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)
                    );

                    INSERT INTO intervals_v2
                        (id, session_id, kind, started_at_utc, ended_at_utc, source,
                         minimum_satisfied_at_utc, created_at_utc)
                    SELECT id, session_id, kind, started_at_utc, ended_at_utc, source,
                           minimum_satisfied_at_utc, created_at_utc
                    FROM intervals;

                    DROP TABLE intervals;
                    ALTER TABLE intervals_v2 RENAME TO intervals;

                    CREATE UNIQUE INDEX one_open_interval
                    ON intervals((1)) WHERE ended_at_utc IS NULL;

                    PRAGMA user_version = 2;
                    """
                )
            }
            version = 2
        }

        if version == 2 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE intervals_v3 (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL CHECK (kind IN ('focus', 'break', 'lunch', 'away')),
                        started_at_utc REAL NOT NULL,
                        ended_at_utc REAL,
                        source TEXT NOT NULL,
                        minimum_satisfied_at_utc REAL,
                        created_at_utc REAL NOT NULL,
                        CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)
                    );

                    INSERT INTO intervals_v3
                        (id, session_id, kind, started_at_utc, ended_at_utc, source,
                         minimum_satisfied_at_utc, created_at_utc)
                    SELECT id, session_id, kind, started_at_utc, ended_at_utc, source,
                           minimum_satisfied_at_utc, created_at_utc
                    FROM intervals;

                    DROP TABLE intervals;
                    ALTER TABLE intervals_v3 RENAME TO intervals;

                    CREATE UNIQUE INDEX one_open_interval
                    ON intervals((1)) WHERE ended_at_utc IS NULL;

                    PRAGMA user_version = 3;
                    """
                )
            }
            version = 3
        }

        if version == 3 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE intervals_v4 (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL CHECK (kind IN ('focus', 'break', 'lunch', 'away', 'travel', 'meeting')),
                        started_at_utc REAL NOT NULL,
                        ended_at_utc REAL,
                        source TEXT NOT NULL,
                        minimum_satisfied_at_utc REAL,
                        created_at_utc REAL NOT NULL,
                        CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)
                    );

                    INSERT INTO intervals_v4
                        (id, session_id, kind, started_at_utc, ended_at_utc, source,
                         minimum_satisfied_at_utc, created_at_utc)
                    SELECT id, session_id, kind, started_at_utc, ended_at_utc, source,
                           minimum_satisfied_at_utc, created_at_utc
                    FROM intervals;

                    DROP TABLE intervals;
                    ALTER TABLE intervals_v4 RENAME TO intervals;

                    CREATE UNIQUE INDEX one_open_interval
                    ON intervals((1)) WHERE ended_at_utc IS NULL;

                    PRAGMA user_version = 4;
                    """
                )
            }
            version = 4
        }

        if version == 4 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE intervals_v5 (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL CHECK (kind IN ('focus', 'break', 'lunch', 'away', 'travel', 'meeting')),
                        started_at_utc REAL NOT NULL,
                        ended_at_utc REAL,
                        source TEXT NOT NULL,
                        minimum_satisfied_at_utc REAL,
                        created_at_utc REAL NOT NULL,
                        corrected_from_kind TEXT CHECK (
                            corrected_from_kind IS NULL OR
                            corrected_from_kind IN ('focus', 'break', 'lunch', 'away', 'travel', 'meeting')
                        ),
                        updated_at_utc REAL NOT NULL,
                        CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)
                    );

                    INSERT INTO intervals_v5
                        (id, session_id, kind, started_at_utc, ended_at_utc, source,
                         minimum_satisfied_at_utc, created_at_utc, corrected_from_kind,
                         updated_at_utc)
                    SELECT id, session_id, kind, started_at_utc, ended_at_utc, source,
                           minimum_satisfied_at_utc, created_at_utc, NULL, created_at_utc
                    FROM intervals;

                    DROP TABLE intervals;
                    ALTER TABLE intervals_v5 RENAME TO intervals;

                    CREATE UNIQUE INDEX one_open_interval
                    ON intervals((1)) WHERE ended_at_utc IS NULL;

                    PRAGMA user_version = 5;
                    """
                )
            }
            version = 5
        }

        if version == 5 {
            try transaction {
                try execute(
                    """
                    ALTER TABLE work_sessions
                    ADD COLUMN corrected_from_started_at_utc REAL;

                    ALTER TABLE work_sessions
                    ADD COLUMN corrected_from_ended_at_utc REAL;

                    ALTER TABLE work_sessions
                    ADD COLUMN updated_at_utc REAL NOT NULL DEFAULT 0;

                    UPDATE work_sessions
                    SET updated_at_utc = created_at_utc;

                    PRAGMA user_version = 6;
                    """
                )
            }
        }
    }

    private func insertSession(id: String, startedAt: Date) throws {
        let createdAt = Date()
        try withStatement(
            """
            INSERT INTO work_sessions
                (id, started_at_utc, created_at_utc, updated_at_utc)
            VALUES (?, ?, ?, ?)
            """
        ) { statement in
            try bind(id, to: statement, at: 1)
            try bind(startedAt, to: statement, at: 2)
            try bind(createdAt, to: statement, at: 3)
            try bind(createdAt, to: statement, at: 4)
            try stepDone(statement)
        }
    }

    private func insertInterval(
        sessionID: String,
        phase: BreakBarPhase,
        startedAt: Date,
        minimumSatisfiedAt: Date?
    ) throws {
        let kind: String
        switch phase {
        case .focusing: kind = "focus"
        case .onBreak: kind = "break"
        case .onLunch: kind = "lunch"
        case .awayUnclassified: kind = "away"
        case .traveling: kind = "travel"
        case .offsiteMeeting: kind = "meeting"
        case .clockedOut:
            throw SessionRepositoryError.unsupportedTransition(from: phase, to: phase)
        }

        try insertInterval(
            sessionID: sessionID,
            kind: kind,
            startedAt: startedAt,
            minimumSatisfiedAt: minimumSatisfiedAt
        )
    }

    private func insertInterval(
        sessionID: String,
        kind: String,
        startedAt: Date,
        minimumSatisfiedAt: Date?
    ) throws {
        let createdAt = Date()
        try withStatement(
            """
            INSERT INTO intervals
                (id, session_id, kind, started_at_utc, source, minimum_satisfied_at_utc,
                 created_at_utc, updated_at_utc)
            VALUES (?, ?, ?, ?, 'state_machine', ?, ?, ?)
            """
        ) { statement in
            try bind(UUID().uuidString, to: statement, at: 1)
            try bind(sessionID, to: statement, at: 2)
            try bind(kind, to: statement, at: 3)
            try bind(startedAt, to: statement, at: 4)
            try bind(minimumSatisfiedAt, to: statement, at: 5)
            try bind(createdAt, to: statement, at: 6)
            try bind(createdAt, to: statement, at: 7)
            try stepDone(statement)
        }
    }

    private func reconcileMeetingInterval(
        from previous: BreakBarState,
        to next: BreakBarState,
        at date: Date
    ) throws {
        let endedScheduledMeeting = next.lastTransitionReason == .scheduledMeetingEnded
            && previous.calendarMeetingStartsAt != nil
        let wasMeeting = Self.isMeeting(previous) || endedScheduledMeeting
        let isMeeting = Self.isMeeting(next)
        guard wasMeeting != isMeeting else { return }

        let openInterval: (kind: String, startedAt: Date)? = try queryOne(
            "SELECT kind, started_at_utc FROM intervals WHERE ended_at_utc IS NULL"
        ) { statement in
            (
                String(cString: sqlite3_column_text(statement, 0)),
                Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            )
        }
        guard let openInterval else { throw SessionRepositoryError.missingOpenInterval }

        let expectedCurrentKind = wasMeeting ? "meeting" : "focus"
        if openInterval.kind != expectedCurrentKind {
            if wasMeeting, !isMeeting, openInterval.kind == "focus" {
                try splitLegacyFocusInterval(
                    openIntervalStartedAt: openInterval.startedAt,
                    meetingStartedAt: Self.meetingStartedAt(in: previous) ?? date,
                    meetingEndedAt: previous.calendarMeetingEndsAt ?? date,
                    transitionDate: date
                )
                return
            }
            if !wasMeeting, isMeeting, openInterval.kind == "meeting" {
                return
            }
            throw SessionRepositoryError.sqlite(
                "The open activity interval does not match the recoverable timer state."
            )
        }

        let proposedBoundary: Date
        if isMeeting {
            proposedBoundary = next.manualMeetingStartedAt
                ?? next.liveCallStartedAt
                ?? next.scheduledMeetingStartedAt
                ?? date
        } else if previous.manualMeetingStartedAt != nil
                    || previous.liveCallStartedAt != nil
        {
            proposedBoundary = date
        } else {
            proposedBoundary = previous.calendarMeetingEndsAt ?? date
        }
        let boundary = min(date, max(openInterval.startedAt, proposedBoundary))
        let sessionID = try openSessionID()
        try closeOpenInterval(at: boundary)
        try insertInterval(
            sessionID: sessionID,
            kind: isMeeting ? "meeting" : "focus",
            startedAt: boundary,
            minimumSatisfiedAt: nil
        )
    }

    private static func isMeeting(_ state: BreakBarState) -> Bool {
        state.manualMeetingStartedAt != nil
            || state.liveCallStartedAt != nil
            || state.scheduledMeetingStartedAt != nil
    }

    private static func meetingStartedAt(in state: BreakBarState) -> Date? {
        [
            state.manualMeetingStartedAt,
            state.liveCallStartedAt,
            state.scheduledMeetingStartedAt,
            state.calendarMeetingStartsAt,
        ]
        .compactMap { $0 }
        .min()
    }

    private func splitLegacyFocusInterval(
        openIntervalStartedAt: Date,
        meetingStartedAt: Date,
        meetingEndedAt: Date,
        transitionDate: Date
    ) throws {
        let sessionID = try openSessionID()
        let start = min(transitionDate, max(openIntervalStartedAt, meetingStartedAt))
        let end = min(transitionDate, max(start, meetingEndedAt))
        guard start < end else { return }

        try closeOpenInterval(at: start)
        try insertInterval(
            sessionID: sessionID,
            kind: "meeting",
            startedAt: start,
            minimumSatisfiedAt: nil
        )
        try closeOpenInterval(at: end)
        try insertInterval(
            sessionID: sessionID,
            kind: "focus",
            startedAt: end,
            minimumSatisfiedAt: nil
        )
    }

    private func openSessionID() throws -> String {
        let id: String? = try queryOne(
            "SELECT id FROM work_sessions WHERE ended_at_utc IS NULL"
        ) { statement in
            String(cString: sqlite3_column_text(statement, 0))
        }
        guard let id else { throw SessionRepositoryError.missingOpenSession }
        return id
    }

    private func workSessionHistory(from statement: OpaquePointer) -> WorkSessionHistory {
        WorkSessionHistory(
            id: String(cString: sqlite3_column_text(statement, 0)),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            endedAt: optionalDate(in: statement, at: 2),
            correctedFromStartedAt: optionalDate(in: statement, at: 3),
            correctedFromEndedAt: optionalDate(in: statement, at: 4),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private func activityHistoryInterval(
        from statement: OpaquePointer
    ) throws -> ActivityHistoryInterval {
        let rawKind = String(cString: sqlite3_column_text(statement, 2))
        guard let kind = ActivityKind(rawValue: rawKind) else {
            throw SessionRepositoryError.sqlite("Unknown activity kind: \(rawKind)")
        }
        let correctedFromKind: ActivityKind?
        if sqlite3_column_type(statement, 6) == SQLITE_NULL {
            correctedFromKind = nil
        } else {
            let rawCorrectedKind = String(cString: sqlite3_column_text(statement, 6))
            guard let parsedKind = ActivityKind(rawValue: rawCorrectedKind) else {
                throw SessionRepositoryError.sqlite(
                    "Unknown original activity kind: \(rawCorrectedKind)"
                )
            }
            correctedFromKind = parsedKind
        }
        return ActivityHistoryInterval(
            id: String(cString: sqlite3_column_text(statement, 0)),
            sessionID: String(cString: sqlite3_column_text(statement, 1)),
            kind: kind,
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            endedAt: optionalDate(in: statement, at: 4),
            source: String(cString: sqlite3_column_text(statement, 5)),
            correctedFromKind: correctedFromKind,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    private func closeOpenInterval(at date: Date) throws {
        try withStatement(
            "UPDATE intervals SET ended_at_utc = ?, updated_at_utc = ? WHERE ended_at_utc IS NULL"
        ) { statement in
            try bind(date, to: statement, at: 1)
            try bind(Date(), to: statement, at: 2)
            try stepDone(statement)
        }
        guard sqlite3_changes(database) == 1 else {
            throw SessionRepositoryError.missingOpenInterval
        }
    }

    private func resolveOpenAwayInterval(as kind: String, endedAt date: Date) throws {
        try withStatement(
            """
            UPDATE intervals
            SET kind = ?, ended_at_utc = ?, updated_at_utc = ?
            WHERE ended_at_utc IS NULL AND kind = 'away'
            """
        ) { statement in
            try bind(kind, to: statement, at: 1)
            try bind(date, to: statement, at: 2)
            try bind(Date(), to: statement, at: 3)
            try stepDone(statement)
        }
        guard sqlite3_changes(database) == 1 else {
            throw SessionRepositoryError.missingOpenInterval
        }
    }

    private func restoreFocusAcrossOpenAwayInterval(sessionID: String) throws {
        try execute("DELETE FROM intervals WHERE ended_at_utc IS NULL AND kind = 'away'")
        guard sqlite3_changes(database) == 1 else {
            throw SessionRepositoryError.missingOpenInterval
        }

        try withStatement(
            """
            UPDATE intervals
            SET ended_at_utc = NULL, updated_at_utc = ?
            WHERE id = (
                SELECT id
                FROM intervals
                WHERE session_id = ? AND kind = 'focus'
                ORDER BY started_at_utc DESC
                LIMIT 1
            )
            """
        ) { statement in
            try bind(Date(), to: statement, at: 1)
            try bind(sessionID, to: statement, at: 2)
            try stepDone(statement)
        }
        guard sqlite3_changes(database) == 1 else {
            throw SessionRepositoryError.missingOpenInterval
        }
    }

    private func closeOpenSession(at date: Date) throws {
        try withStatement(
            """
            UPDATE work_sessions
            SET ended_at_utc = ?, updated_at_utc = ?
            WHERE ended_at_utc IS NULL
            """
        ) { statement in
            try bind(date, to: statement, at: 1)
            try bind(Date(), to: statement, at: 2)
            try stepDone(statement)
        }
        guard sqlite3_changes(database) == 1 else {
            throw SessionRepositoryError.missingOpenSession
        }
    }

    private func saveSnapshot(_ state: BreakBarState) throws {
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw SessionRepositoryError.sqlite("Could not encode the timer state: \(error.localizedDescription)")
        }

        try withStatement(
            """
            INSERT INTO state_snapshot (singleton_id, revision, payload, updated_at_utc)
            VALUES (1, ?, ?, ?)
            ON CONFLICT(singleton_id) DO UPDATE SET
                revision = excluded.revision,
                payload = excluded.payload,
                updated_at_utc = excluded.updated_at_utc
            """
        ) { statement in
            guard sqlite3_bind_int64(statement, 1, Int64(state.revision)) == SQLITE_OK else {
                throw lastError()
            }
            try bind(data, to: statement, at: 2)
            try bind(Date(), to: statement, at: 3)
            try stepDone(statement)
        }
    }

    private func count(_ sql: String) throws -> Int {
        try queryOne(sql) { Int(sqlite3_column_int64($0, 0)) } ?? 0
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func checkpointAndTruncateWAL() throws {
        guard let database else {
            throw SessionRepositoryError.sqlite("The history database is unavailable.")
        }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? lastError().localizedDescription
            sqlite3_free(errorMessage)
            throw SessionRepositoryError.sqlite(message)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func queryOne<T>(
        _ sql: String,
        transform: (OpaquePointer) throws -> T
    ) throws -> T? {
        try withStatement(sql) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return try transform(statement)
            case SQLITE_DONE: return nil
            default: throw lastError()
            }
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: Date, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value.timeIntervalSince1970) == SQLITE_OK else {
            throw lastError()
        }
    }

    private func bind(_ value: Date?, to statement: OpaquePointer, at index: Int32) throws {
        if let value {
            try bind(value, to: statement, at: index)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw lastError()
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func optionalDate(in statement: OpaquePointer, at index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func lastError() -> SessionRepositoryError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
            ?? "Unknown SQLite error"
        return .sqlite(message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
