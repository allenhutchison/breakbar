import BreakBarCore
@testable import BreakBarPersistence
import CSQLite
import Foundation
import XCTest

final class SessionRepositoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)
    private let policy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20
    )

    func testFullCycleProducesClosedSessionAndIntervalLedger() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)

            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .startBreak,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )
            try commit(
                .returnToFocus,
                at: origin.addingTimeInterval(80),
                engine: &engine,
                repository: repository
            )
            try commit(
                .clockOut,
                at: origin.addingTimeInterval(90),
                engine: &engine,
                repository: repository
            )

            XCTAssertEqual(
                try repository.stats(),
                SessionRepositoryStats(
                    totalSessions: 1,
                    openSessions: 0,
                    totalIntervals: 3,
                    openIntervals: 0,
                    focusIntervals: 2,
                    breakIntervals: 1
                )
            )
            XCTAssertEqual(try repository.loadState(), engine.state)
        }
    }

    func testEveryActivePhaseAndEnforcementStateRecoversAfterReopen() throws {
        let scenarios: [(commands: [(BreakCommand, TimeInterval)], intervalCount: Int)] = [
            ([(.clockIn, 0)], 1),
            ([(.clockIn, 0), (.tick, 50)], 1),
            ([(.clockIn, 0), (.tick, 60)], 1),
            ([(.clockIn, 0), (.startBreak, 60)], 2),
            ([(.clockIn, 0), (.startLunch, 30)], 2),
            ([(.clockIn, 0), (.startManualMeeting, 30)], 1),
            ([
                (.clockIn, 0),
                (.idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)), 30),
            ], 2),
        ]

        for scenario in scenarios {
            try withRepository { repository, databaseURL in
                var engine = BreakBarEngine(policy: policy)
                try repository.bootstrapIfNeeded(state: engine.state, at: origin)
                for (command, offset) in scenario.commands {
                    try commit(
                        command,
                        at: origin.addingTimeInterval(offset),
                        engine: &engine,
                        repository: repository
                    )
                }

                let reopened = try SessionRepository(url: databaseURL)
                XCTAssertEqual(try reopened.loadState(), engine.state)
                XCTAssertEqual(try reopened.stats().openSessions, 1)
                XCTAssertEqual(try reopened.stats().openIntervals, 1)
                XCTAssertEqual(try reopened.stats().totalIntervals, scenario.intervalCount)
            }
        }
    }

    func testActiveLegacySnapshotBootstrapsAnOpenLedger() throws {
        try withRepository { repository, _ in
            let legacy = BreakBarState(
                phase: .onBreak,
                enforcement: .none,
                phaseStartedAt: origin,
                minimumBreakEndsAt: origin.addingTimeInterval(20),
                revision: 4
            )

            try repository.bootstrapIfNeeded(state: legacy, at: origin)

            XCTAssertEqual(try repository.loadState(), legacy)
            XCTAssertEqual(
                try repository.stats(),
                SessionRepositoryStats(
                    totalSessions: 1,
                    openSessions: 1,
                    totalIntervals: 1,
                    openIntervals: 1,
                    focusIntervals: 0,
                    breakIntervals: 1
                )
            )
        }
    }

    func testRecoveredBreakCanContinueIntoFreshFocus() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .startBreak,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            let recoveredState = try XCTUnwrap(reopened.loadState())
            var recoveredEngine = BreakBarEngine(state: recoveredState, policy: policy)
            try commit(
                .returnToFocus,
                at: origin.addingTimeInterval(80),
                engine: &recoveredEngine,
                repository: reopened
            )

            XCTAssertEqual(recoveredEngine.state.phase, .focusing)
            XCTAssertEqual(try reopened.stats().openSessions, 1)
            XCTAssertEqual(try reopened.stats().openIntervals, 1)
            XCTAssertEqual(try reopened.stats().totalIntervals, 3)
        }
    }

    func testLunchPersistsAndReturnsToFreshFocus() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .startLunch,
                at: origin.addingTimeInterval(30),
                engine: &engine,
                repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            let recoveredState = try XCTUnwrap(reopened.loadState())
            XCTAssertEqual(recoveredState.phase, .onLunch)
            XCTAssertEqual(try reopened.stats().lunchIntervals, 1)
            XCTAssertEqual(try reopened.stats().openIntervals, 1)

            var recoveredEngine = BreakBarEngine(state: recoveredState, policy: policy)
            let lunchEndedAt = origin.addingTimeInterval(120)
            try commit(
                .endLunch,
                at: lunchEndedAt,
                engine: &recoveredEngine,
                repository: reopened
            )

            XCTAssertEqual(recoveredEngine.state.phase, .focusing)
            XCTAssertEqual(recoveredEngine.state.focusDueAt, lunchEndedAt.addingTimeInterval(60))
            XCTAssertEqual(try reopened.stats().totalIntervals, 3)
            XCTAssertEqual(try reopened.stats().focusIntervals, 2)
            XCTAssertEqual(try reopened.stats().lunchIntervals, 1)
        }
    }

    func testClockingOutFromLunchClosesSessionAndInterval() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .startLunch,
                at: origin.addingTimeInterval(30),
                engine: &engine,
                repository: repository
            )
            try commit(
                .clockOut,
                at: origin.addingTimeInterval(90),
                engine: &engine,
                repository: repository
            )

            XCTAssertEqual(engine.state.phase, .clockedOut)
            XCTAssertEqual(try repository.stats().openSessions, 0)
            XCTAssertEqual(try repository.stats().openIntervals, 0)
            XCTAssertEqual(try repository.stats().lunchIntervals, 1)
        }
    }

    func testVersionOneDatabaseMigratesWithoutLosingHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("breakbar.sqlite")
        try createVersionOneDatabase(at: databaseURL)

        let repository = try SessionRepository(url: databaseURL)
        XCTAssertEqual(try repository.stats().totalSessions, 1)
        XCTAssertEqual(try repository.stats().focusIntervals, 1)

        var engine = BreakBarEngine(policy: policy)
        try repository.bootstrapIfNeeded(state: engine.state, at: origin)
        try commit(.clockIn, at: origin, engine: &engine, repository: repository)
        try commit(
            .startLunch,
            at: origin.addingTimeInterval(30),
            engine: &engine,
            repository: repository
        )

        XCTAssertEqual(try repository.stats().totalIntervals, 3)
        XCTAssertEqual(try repository.stats().focusIntervals, 2)
        XCTAssertEqual(try repository.stats().lunchIntervals, 1)
    }

    func testAwayClassificationsRewriteHistoryAndStartFreshFocus() throws {
        let cases: [(AwayClassification, focus: Int, breaks: Int, lunches: Int, away: Int)] = [
            (.lunch, 2, 0, 1, 0),
            (.breakTime, 2, 1, 0, 0),
            (.otherAway, 2, 0, 0, 1),
        ]

        for testCase in cases {
            try withRepository { repository, _ in
                var engine = BreakBarEngine(policy: policy)
                try repository.bootstrapIfNeeded(state: engine.state, at: origin)
                try commit(.clockIn, at: origin, engine: &engine, repository: repository)
                try commit(
                    .idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)),
                    at: origin.addingTimeInterval(30),
                    engine: &engine,
                    repository: repository
                )
                try commit(
                    .userActivityResumed,
                    at: origin.addingTimeInterval(80),
                    engine: &engine,
                    repository: repository
                )
                try commit(
                    .classifyAway(testCase.0),
                    at: origin.addingTimeInterval(85),
                    engine: &engine,
                    repository: repository
                )

                let stats = try repository.stats()
                XCTAssertEqual(stats.totalIntervals, 3)
                XCTAssertEqual(stats.openIntervals, 1)
                XCTAssertEqual(stats.focusIntervals, testCase.focus)
                XCTAssertEqual(stats.breakIntervals, testCase.breaks)
                XCTAssertEqual(stats.lunchIntervals, testCase.lunches)
                XCTAssertEqual(stats.awayIntervals, testCase.away)
                XCTAssertEqual(engine.state.phaseStartedAt, origin.addingTimeInterval(80))
            }
        }
    }

    func testCountAsWorkMergesTentativeAwayBackIntoFocus() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)),
                at: origin.addingTimeInterval(30),
                engine: &engine,
                repository: repository
            )
            try commit(
                .userActivityResumed,
                at: origin.addingTimeInterval(80),
                engine: &engine,
                repository: repository
            )
            try commit(
                .classifyAway(.countAsWork),
                at: origin.addingTimeInterval(85),
                engine: &engine,
                repository: repository
            )

            let stats = try repository.stats()
            XCTAssertEqual(stats.totalIntervals, 1)
            XCTAssertEqual(stats.openIntervals, 1)
            XCTAssertEqual(stats.focusIntervals, 1)
            XCTAssertEqual(stats.awayIntervals, 0)

            let reopened = try SessionRepository(url: databaseURL)
            XCTAssertEqual(try reopened.loadState(), engine.state)
        }
    }

    func testVersionTwoDatabaseMigratesToAwaySchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarV2MigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("breakbar.sqlite")
        try createVersionTwoDatabase(at: databaseURL)

        let repository = try SessionRepository(url: databaseURL)
        XCTAssertEqual(try repository.stats().focusIntervals, 1)
        XCTAssertEqual(try repository.stats().awayIntervals, 0)

        var engine = BreakBarEngine(policy: policy)
        try repository.bootstrapIfNeeded(state: engine.state, at: origin)
        try commit(.clockIn, at: origin, engine: &engine, repository: repository)
        try commit(
            .idleThresholdReached(idleStartedAt: origin.addingTimeInterval(20)),
            at: origin.addingTimeInterval(30),
            engine: &engine,
            repository: repository
        )

        XCTAssertEqual(try repository.stats().awayIntervals, 1)
    }

    func testEmergencyTransitionReasonSurvivesReopen() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .emergencyStartBreak,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            XCTAssertEqual(
                try reopened.loadState()?.lastTransitionReason,
                .emergencyStartBreak
            )
        }
    }

    func testCalendarPlanPersistsWithoutSplittingFocusHistory() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let meeting = BreakCalendarConstraint(
                id: "transient-event-id",
                startAt: origin.addingTimeInterval(70),
                endAt: origin.addingTimeInterval(120)
            )
            try commit(
                .updateCalendarConstraints([meeting]),
                at: origin,
                engine: &engine,
                repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            let recovered = try XCTUnwrap(reopened.loadState())
            XCTAssertEqual(recovered.focusDueAt, origin.addingTimeInterval(50))
            XCTAssertEqual(recovered.breakPlanReason, .pulledBeforeMeeting)
            XCTAssertEqual(try reopened.stats().totalIntervals, 1)
            XCTAssertEqual(try reopened.stats().openIntervals, 1)
        }
    }

    func testTravelChainPersistsAndRecordsTravelAndOffsiteIntervals() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let outbound = BreakCalendarConstraint(
                id: "outbound", startAt: origin.addingTimeInterval(100),
                endAt: origin.addingTimeInterval(200), kind: .travel
            )
            let offsite = BreakCalendarConstraint(
                id: "offsite", startAt: origin.addingTimeInterval(200),
                endAt: origin.addingTimeInterval(300), kind: .offsiteMeeting
            )
            let returning = BreakCalendarConstraint(
                id: "return", startAt: origin.addingTimeInterval(300),
                endAt: origin.addingTimeInterval(400), kind: .travel
            )
            let chain = [outbound, offsite, returning]
            try commit(
                .updateCalendarConstraints(chain), at: origin,
                engine: &engine, repository: repository
            )
            try commit(
                .tick, at: origin.addingTimeInterval(100),
                engine: &engine, repository: repository
            )
            try commit(
                .acknowledgeTravel, at: origin.addingTimeInterval(101),
                engine: &engine, repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            var recoveredEngine = BreakBarEngine(
                state: try XCTUnwrap(reopened.loadState()),
                policy: policy
            )
            XCTAssertEqual(recoveredEngine.state.travelChain, chain)
            try commit(
                .tick, at: origin.addingTimeInterval(200),
                engine: &recoveredEngine, repository: reopened
            )
            try commit(
                .tick, at: origin.addingTimeInterval(300),
                engine: &recoveredEngine, repository: reopened
            )
            try commit(
                .returnHome, at: origin.addingTimeInterval(400),
                engine: &recoveredEngine, repository: reopened
            )

            let stats = try reopened.stats()
            XCTAssertEqual(stats.totalIntervals, 5)
            XCTAssertEqual(stats.travelIntervals, 2)
            XCTAssertEqual(stats.meetingIntervals, 1)
            XCTAssertEqual(stats.focusIntervals, 2)
            XCTAssertEqual(recoveredEngine.state.phase, .focusing)
        }
    }

    func testLiveCallPersistsWithoutSplittingFocusHistory() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .updateCallActivity(
                    BreakCallSignal(
                        bundleIdentifier: "us.zoom.xos",
                        confidence: .dedicatedApplication
                    )
                ),
                at: origin.addingTimeInterval(10),
                engine: &engine,
                repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            let recovered = try XCTUnwrap(reopened.loadState())
            XCTAssertEqual(recovered.liveCallStartedAt, origin.addingTimeInterval(10))
            XCTAssertEqual(recovered.liveCallBundleIdentifier, "us.zoom.xos")
            XCTAssertEqual(recovered.liveCallConfidence, .dedicatedApplication)
            XCTAssertEqual(try reopened.stats().totalIntervals, 1)
            XCTAssertEqual(try reopened.stats().openIntervals, 1)
        }
    }

    func testStaleTransitionRollsBackWithoutChangingHistory() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)

            var stale = engine.state
            stale.revision += 1
            var candidate = BreakBarEngine(state: stale, policy: policy)
            _ = candidate.handle(.startBreak, at: origin.addingTimeInterval(60))

            XCTAssertThrowsError(
                try repository.commitTransition(
                    from: stale,
                    to: candidate.state,
                    at: origin.addingTimeInterval(60)
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .staleState)
            }

            XCTAssertEqual(try repository.loadState(), engine.state)
            XCTAssertEqual(try repository.stats().openSessions, 1)
            XCTAssertEqual(try repository.stats().openIntervals, 1)
            XCTAssertEqual(try repository.stats().totalIntervals, 1)
        }
    }

    private func commit(
        _ command: BreakCommand,
        at date: Date,
        engine: inout BreakBarEngine,
        repository: SessionRepository
    ) throws {
        let previous = engine.state
        var candidate = engine
        XCTAssertEqual(candidate.handle(command, at: date), .changed)
        try repository.commitTransition(from: previous, to: candidate.state, at: date)
        engine = candidate
    }

    private func withRepository(
        _ body: (SessionRepository, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarPersistenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("breakbar.sqlite")
        let repository = try SessionRepository(url: databaseURL)
        try body(repository, databaseURL)
    }

    private func createVersionOneDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "BreakBarMigrationTests", code: 1)
        }
        defer { sqlite3_close(database) }

        let sql =
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
                kind TEXT NOT NULL CHECK (kind IN ('focus', 'break')),
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
            INSERT INTO work_sessions
                (id, started_at_utc, ended_at_utc, created_at_utc)
            VALUES ('old-session', 10, 20, 10);
            INSERT INTO intervals
                (id, session_id, kind, started_at_utc, ended_at_utc, source, created_at_utc)
            VALUES ('old-focus', 'old-session', 'focus', 10, 20, 'state_machine', 10);
            PRAGMA user_version = 1;
            """

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "BreakBarMigrationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func createVersionTwoDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "BreakBarV2MigrationTests", code: 1)
        }
        defer { sqlite3_close(database) }

        let sql =
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
                kind TEXT NOT NULL CHECK (kind IN ('focus', 'break', 'lunch')),
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
            INSERT INTO work_sessions
                (id, started_at_utc, ended_at_utc, created_at_utc)
            VALUES ('old-session', 10, 20, 10);
            INSERT INTO intervals
                (id, session_id, kind, started_at_utc, ended_at_utc, source, created_at_utc)
            VALUES ('old-focus', 'old-session', 'focus', 10, 20, 'state_machine', 10);
            PRAGMA user_version = 2;
            """

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "BreakBarV2MigrationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
