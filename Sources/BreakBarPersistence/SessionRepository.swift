import BreakBarCore
import CSQLite
import Foundation

public enum SessionRepositoryError: Error, LocalizedError, Equatable {
    case couldNotOpen(String)
    case sqlite(String)
    case staleState
    case missingOpenSession
    case missingOpenInterval
    case unsupportedTransition(from: BreakBarPhase, to: BreakBarPhase)

    public var errorDescription: String? {
        switch self {
        case let .couldNotOpen(message), let .sqlite(message): message
        case .staleState: "The saved state changed before this transition could be committed."
        case .missingOpenSession: "The active timer has no open work session."
        case .missingOpenInterval: "The active timer has no open activity interval."
        case let .unsupportedTransition(from, to):
            "Unsupported timer transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
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

    public init(
        totalSessions: Int,
        openSessions: Int,
        totalIntervals: Int,
        openIntervals: Int,
        focusIntervals: Int,
        breakIntervals: Int,
        lunchIntervals: Int = 0,
        awayIntervals: Int = 0
    ) {
        self.totalSessions = totalSessions
        self.openSessions = openSessions
        self.totalIntervals = totalIntervals
        self.openIntervals = openIntervals
        self.focusIntervals = focusIntervals
        self.breakIntervals = breakIntervals
        self.lunchIntervals = lunchIntervals
        self.awayIntervals = awayIntervals
    }
}

public final class SessionRepository {
    public static let schemaVersion = 3

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

            case (.focusing, .clockedOut),
                 (.onBreak, .clockedOut),
                 (.onLunch, .clockedOut),
                 (.awayUnclassified, .clockedOut):
                _ = try openSessionID()
                try closeOpenInterval(at: date)
                try closeOpenSession(at: date)

            case (.focusing, .focusing),
                 (.onBreak, .onBreak),
                 (.onLunch, .onLunch),
                 (.awayUnclassified, .awayUnclassified),
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
            awayIntervals: try count("SELECT COUNT(*) FROM intervals WHERE kind = 'away'")
        )
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
                    created_at_utc REAL NOT NULL
                );

                CREATE UNIQUE INDEX one_open_work_session
                ON work_sessions((1)) WHERE ended_at_utc IS NULL;

                CREATE TABLE intervals (
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

                CREATE UNIQUE INDEX one_open_interval
                ON intervals((1)) WHERE ended_at_utc IS NULL;

                CREATE TABLE state_snapshot (
                    singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
                    revision INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    updated_at_utc REAL NOT NULL
                );

                PRAGMA user_version = 3;
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
        }
    }

    private func insertSession(id: String, startedAt: Date) throws {
        try withStatement(
            "INSERT INTO work_sessions (id, started_at_utc, created_at_utc) VALUES (?, ?, ?)"
        ) { statement in
            try bind(id, to: statement, at: 1)
            try bind(startedAt, to: statement, at: 2)
            try bind(Date(), to: statement, at: 3)
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
        case .clockedOut:
            throw SessionRepositoryError.unsupportedTransition(from: phase, to: phase)
        }

        try withStatement(
            """
            INSERT INTO intervals
                (id, session_id, kind, started_at_utc, source, minimum_satisfied_at_utc, created_at_utc)
            VALUES (?, ?, ?, ?, 'state_machine', ?, ?)
            """
        ) { statement in
            try bind(UUID().uuidString, to: statement, at: 1)
            try bind(sessionID, to: statement, at: 2)
            try bind(kind, to: statement, at: 3)
            try bind(startedAt, to: statement, at: 4)
            try bind(minimumSatisfiedAt, to: statement, at: 5)
            try bind(Date(), to: statement, at: 6)
            try stepDone(statement)
        }
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

    private func closeOpenInterval(at date: Date) throws {
        try withStatement(
            "UPDATE intervals SET ended_at_utc = ? WHERE ended_at_utc IS NULL"
        ) { statement in
            try bind(date, to: statement, at: 1)
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
            SET kind = ?, ended_at_utc = ?
            WHERE ended_at_utc IS NULL AND kind = 'away'
            """
        ) { statement in
            try bind(kind, to: statement, at: 1)
            try bind(date, to: statement, at: 2)
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
            SET ended_at_utc = NULL
            WHERE id = (
                SELECT id
                FROM intervals
                WHERE session_id = ? AND kind = 'focus'
                ORDER BY started_at_utc DESC
                LIMIT 1
            )
            """
        ) { statement in
            try bind(sessionID, to: statement, at: 1)
            try stepDone(statement)
        }
        guard sqlite3_changes(database) == 1 else {
            throw SessionRepositoryError.missingOpenInterval
        }
    }

    private func closeOpenSession(at date: Date) throws {
        try withStatement(
            "UPDATE work_sessions SET ended_at_utc = ? WHERE ended_at_utc IS NULL"
        ) { statement in
            try bind(date, to: statement, at: 1)
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

    private func lastError() -> SessionRepositoryError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
            ?? "Unknown SQLite error"
        return .sqlite(message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
