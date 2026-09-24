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

    func testHealthCheckReportsNewDatabaseAsHealthy() throws {
        try withRepository { repository, _ in
            XCTAssertTrue(try repository.isHealthy())
        }
    }

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

    func testCompleteHistoryArchiveIncludesEverySessionAndRoundTripsAsJSON() throws {
        try withRepository { repository, _ in
            let history = try createClosedCycle(in: repository)
            let exportedAt = origin.addingTimeInterval(300)

            let archive = try repository.completeHistory(exportedAt: exportedAt)

            XCTAssertEqual(archive.formatVersion, HistoryArchive.currentFormatVersion)
            XCTAssertEqual(archive.dateEncoding, "secondsSince1970")
            XCTAssertEqual(archive.exportedAt, exportedAt)
            XCTAssertEqual(archive.sessions, history.sessions)
            XCTAssertEqual(archive.intervals, history.intervals)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(archive)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            XCTAssertEqual(try decoder.decode(HistoryArchive.self, from: data), archive)
        }
    }

    func testDeleteAllHistoryPreservesClockedOutStateAndRepositoryUsability() throws {
        try withRepository { repository, databaseURL in
            _ = try createClosedCycle(in: repository)
            let clockedOutState = try XCTUnwrap(repository.loadState())
            let archiveBeforeDeletion = try repository.completeHistory()
            let deletedIdentifiers = archiveBeforeDeletion.sessions.map(\.id)
                + archiveBeforeDeletion.intervals.map(\.id)
            XCTAssertEqual(clockedOutState.phase, .clockedOut)

            XCTAssertEqual(
                try repository.deleteAllHistory(expectedState: clockedOutState),
                .deleted
            )

            XCTAssertEqual(
                try repository.stats(),
                SessionRepositoryStats(
                    totalSessions: 0,
                    openSessions: 0,
                    totalIntervals: 0,
                    openIntervals: 0,
                    focusIntervals: 0,
                    breakIntervals: 0
                )
            )
            XCTAssertEqual(try repository.loadState(), clockedOutState)
            XCTAssertTrue(try repository.completeHistory().sessions.isEmpty)
            XCTAssertTrue(try repository.completeHistory().intervals.isEmpty)

            let storageURLs = [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal"),
            ]
            for storageURL in storageURLs
            where FileManager.default.fileExists(atPath: storageURL.path) {
                let storedBytes = try Data(contentsOf: storageURL)
                for identifier in deletedIdentifiers {
                    XCTAssertNil(storedBytes.range(of: Data(identifier.utf8)))
                }
            }

            var engine = BreakBarEngine(state: clockedOutState, policy: policy)
            try commit(
                .clockIn,
                at: origin.addingTimeInterval(400),
                engine: &engine,
                repository: repository
            )
            XCTAssertEqual(try repository.stats().totalSessions, 1)
            XCTAssertEqual(try repository.stats().openSessions, 1)
        }
    }

    func testDeleteAllHistoryRejectsAnActiveSessionWithoutChangingHistory() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)

            XCTAssertThrowsError(
                try repository.deleteAllHistory(expectedState: engine.state)
            ) { error in
                XCTAssertEqual(
                    error as? SessionRepositoryError,
                    .historyDeletionRequiresClockedOut
                )
            }
            XCTAssertEqual(try repository.stats().totalSessions, 1)
            XCTAssertEqual(try repository.stats().openSessions, 1)
            XCTAssertEqual(try repository.stats().totalIntervals, 1)
        }
    }

    func testEveryActivePhaseAndEnforcementStateRecoversAfterReopen() throws {
        let scenarios: [(commands: [(BreakCommand, TimeInterval)], intervalCount: Int)] = [
            ([(.clockIn, 0)], 1),
            ([(.clockIn, 0), (.tick, 50)], 1),
            ([(.clockIn, 0), (.tick, 60)], 1),
            ([(.clockIn, 0), (.startBreak, 60)], 2),
            ([(.clockIn, 0), (.startLunch, 30)], 2),
            ([(.clockIn, 0), (.startManualMeeting, 30)], 2),
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
        let migratedHistory = try repository.dailyHistory(
            on: Date(timeIntervalSince1970: 15),
            calendar: utcCalendar
        )
        XCTAssertEqual(migratedHistory.intervals.count, 1)
        XCTAssertFalse(migratedHistory.intervals[0].wasCorrected)
        XCTAssertEqual(migratedHistory.intervals[0].updatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(migratedHistory.sessions.count, 1)
        XCTAssertFalse(migratedHistory.sessions[0].wasCorrected)
        XCTAssertEqual(migratedHistory.sessions[0].updatedAt, Date(timeIntervalSince1970: 10))

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

    func testBreakDeferralSurvivesReopenWithoutSplittingFocusHistory() throws {
        try withRepository { repository, databaseURL in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .tick,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )
            try commit(
                .deferBreak(by: 300),
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )

            let reopened = try SessionRepository(url: databaseURL)
            let recovered = try XCTUnwrap(reopened.loadState())
            XCTAssertEqual(recovered.focusDueAt, origin.addingTimeInterval(360))
            XCTAssertEqual(recovered.breakPlanReason, .userDeferred)
            XCTAssertEqual(recovered.lastTransitionReason, .breakDeferred)
            XCTAssertEqual(try reopened.stats().focusIntervals, 1)
            XCTAssertEqual(try reopened.stats().openIntervals, 1)
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

    func testClockOutBeforeTravelReturnSplitsOvernightSessionAndPreservesCurrentFocus() throws {
        try withRepository { repository, databaseURL in
            let day = utcCalendar.date(
                from: DateComponents(year: 2026, month: 9, day: 23, hour: 19)
            )!
            let travelStartsAt = day.addingTimeInterval(60 * 60)
            let clockedOutAt = day.addingTimeInterval(90 * 60)
            let chainEndsAt = day.addingTimeInterval(14 * 60 * 60)
            let returnedAt = day.addingTimeInterval(14 * 60 * 60 + 10 * 60)
            let correctedAt = returnedAt.addingTimeInterval(60 * 60)
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: day)
            try commit(.clockIn, at: day, engine: &engine, repository: repository)
            let travel = BreakCalendarConstraint(
                id: "overnight-travel", startAt: travelStartsAt,
                endAt: chainEndsAt, kind: .travel
            )
            try commit(
                .updateCalendarConstraints([travel]), at: day,
                engine: &engine, repository: repository
            )
            try commit(.tick, at: travelStartsAt, engine: &engine, repository: repository)
            try commit(.returnHome, at: returnedAt, engine: &engine, repository: repository)

            let original = try repository.dailyHistory(on: returnedAt, calendar: utcCalendar)
            let interval = try XCTUnwrap(original.intervals.first { $0.kind == .travel })
            XCTAssertEqual(original.summary(at: correctedAt).travel, returnedAt.timeIntervalSince(original.day.start))

            XCTAssertThrowsError(
                try repository.clockOutBeforeTravelReturn(
                    travelIntervalID: interval.id,
                    clockedOutAt: travelStartsAt,
                    expectedState: engine.state,
                    correctedAt: correctedAt
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .travelCorrectionOutsideTravelInterval)
            }
            XCTAssertEqual(try repository.stats().totalSessions, 1)

            XCTAssertThrowsError(
                try repository.clockOutBeforeTravelReturn(
                    travelIntervalID: interval.id,
                    clockedOutAt: clockedOutAt,
                    expectedState: BreakBarState(),
                    correctedAt: correctedAt
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .staleState)
            }

            try repository.clockOutBeforeTravelReturn(
                travelIntervalID: interval.id,
                clockedOutAt: clockedOutAt,
                expectedState: engine.state,
                correctedAt: correctedAt
            )

            let previousDay = try repository.dailyHistory(on: day, calendar: utcCalendar)
            let nextDay = try repository.dailyHistory(on: returnedAt, calendar: utcCalendar)
            XCTAssertEqual(previousDay.sessions.count, 1)
            XCTAssertEqual(previousDay.sessions[0].endedAt, clockedOutAt)
            XCTAssertNil(previousDay.sessions[0].correctedFromEndedAt)
            XCTAssertEqual(previousDay.intervals.last?.kind, .travel)
            XCTAssertEqual(previousDay.intervals.last?.endedAt, clockedOutAt)
            XCTAssertEqual(previousDay.summary(at: correctedAt).clockedIn, 90 * 60)
            XCTAssertEqual(nextDay.sessions.count, 1)
            XCTAssertEqual(nextDay.sessions[0].startedAt, returnedAt)
            XCTAssertEqual(nextDay.intervals.map(\.kind), [.focus])
            XCTAssertEqual(nextDay.summary(at: correctedAt).travel, 0)
            XCTAssertEqual(nextDay.summary(at: correctedAt).clockedIn, 60 * 60)
            XCTAssertEqual(try repository.loadState(), engine.state)
            XCTAssertEqual(try repository.stats().openSessions, 1)
            XCTAssertEqual(try repository.stats().openIntervals, 1)
            XCTAssertEqual(try repository.stats().totalSessions, 2)

            XCTAssertThrowsError(
                try repository.clockOutBeforeTravelReturn(
                    travelIntervalID: interval.id,
                    clockedOutAt: clockedOutAt,
                    expectedState: engine.state,
                    correctedAt: correctedAt
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .travelCorrectionRequiresReturnedFocus)
            }

            let reopened = try SessionRepository(url: databaseURL)
            try commit(
                .clockOut, at: correctedAt,
                engine: &engine, repository: reopened
            )
            XCTAssertEqual(try reopened.stats().openSessions, 0)
        }
    }

    func testTravelClockOutCorrectionAlsoWorksAfterLaterClockOut() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let travel = BreakCalendarConstraint(
                id: "travel", startAt: origin.addingTimeInterval(100),
                endAt: origin.addingTimeInterval(200), kind: .travel
            )
            try commit(
                .updateCalendarConstraints([travel]), at: origin,
                engine: &engine, repository: repository
            )
            try commit(
                .tick, at: origin.addingTimeInterval(100),
                engine: &engine, repository: repository
            )
            try commit(
                .returnHome, at: origin.addingTimeInterval(300),
                engine: &engine, repository: repository
            )
            try commit(
                .clockOut, at: origin.addingTimeInterval(400),
                engine: &engine, repository: repository
            )

            let travelInterval = try XCTUnwrap(
                repository.dailyHistory(on: origin, calendar: utcCalendar)
                    .intervals.first { $0.kind == .travel }
            )
            try repository.clockOutBeforeTravelReturn(
                travelIntervalID: travelInterval.id,
                clockedOutAt: origin.addingTimeInterval(250),
                expectedState: engine.state,
                correctedAt: origin.addingTimeInterval(500)
            )

            let history = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(history.sessions.count, 2)
            XCTAssertEqual(history.sessions[0].endedAt, origin.addingTimeInterval(250))
            XCTAssertEqual(history.sessions[1].startedAt, origin.addingTimeInterval(300))
            XCTAssertEqual(history.sessions[1].endedAt, origin.addingTimeInterval(400))
            XCTAssertEqual(history.intervals.map(\.sessionID), [
                history.sessions[0].id,
                history.sessions[0].id,
                history.sessions[1].id,
            ])
            XCTAssertEqual(history.summary(at: origin.addingTimeInterval(500)).travel, 150)
            XCTAssertEqual(try repository.stats().openSessions, 0)
            XCTAssertEqual(try repository.loadState(), engine.state)
        }
    }

    func testLiveCallSplitsMeetingHistoryFromFocus() throws {
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
            XCTAssertEqual(try reopened.stats().totalIntervals, 2)
            XCTAssertEqual(try reopened.stats().openIntervals, 1)
            XCTAssertEqual(try reopened.stats().focusIntervals, 1)
            XCTAssertEqual(try reopened.stats().meetingIntervals, 1)

            try commit(
                .updateCallActivity(nil),
                at: origin.addingTimeInterval(30),
                engine: &engine,
                repository: repository
            )
            XCTAssertEqual(try repository.stats().totalIntervals, 3)
            XCTAssertEqual(try repository.stats().focusIntervals, 2)
            XCTAssertEqual(try repository.stats().meetingIntervals, 1)
        }
    }

    func testScheduledMeetingSplitsAtCalendarBoundaries() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let meeting = BreakCalendarConstraint(
                id: "meeting",
                startAt: origin.addingTimeInterval(50),
                endAt: origin.addingTimeInterval(90)
            )
            try commit(
                .updateCalendarConstraints([meeting]),
                at: origin,
                engine: &engine,
                repository: repository
            )
            try commit(
                .tick,
                at: origin.addingTimeInterval(50),
                engine: &engine,
                repository: repository
            )
            XCTAssertEqual(engine.state.scheduledMeetingStartedAt, origin.addingTimeInterval(50))

            try commit(
                .tick,
                at: origin.addingTimeInterval(91),
                engine: &engine,
                repository: repository
            )

            let history = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(history.intervals.map(\.kind), [.focus, .meeting, .focus])
            XCTAssertEqual(history.intervals[0].endedAt, origin.addingTimeInterval(50))
            XCTAssertEqual(history.intervals[1].startedAt, origin.addingTimeInterval(50))
            XCTAssertEqual(history.intervals[1].endedAt, origin.addingTimeInterval(90))
            XCTAssertEqual(history.intervals[2].startedAt, origin.addingTimeInterval(90))
        }
    }

    func testLegacyActiveCallSnapshotRepairsFocusLedgerWhenCallEnds() throws {
        try withRepository { repository, _ in
            let callStartedAt = origin.addingTimeInterval(10)
            let legacyState = BreakBarState(
                phase: .focusing,
                phaseStartedAt: origin,
                nominalFocusDueAt: origin.addingTimeInterval(60),
                focusDueAt: origin.addingTimeInterval(60),
                breakPlanReason: .nominal,
                liveCallStartedAt: callStartedAt,
                liveCallBundleIdentifier: "us.zoom.xos",
                liveCallConfidence: .dedicatedApplication,
                revision: 2
            )
            try repository.bootstrapIfNeeded(state: legacyState, at: origin)
            var engine = BreakBarEngine(state: legacyState, policy: policy)

            try commit(
                .updateCallActivity(nil),
                at: origin.addingTimeInterval(30),
                engine: &engine,
                repository: repository
            )

            let history = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(history.intervals.map(\.kind), [.focus, .meeting, .focus])
            XCTAssertEqual(history.intervals[0].endedAt, callStartedAt)
            XCTAssertEqual(history.intervals[1].startedAt, callStartedAt)
            XCTAssertEqual(history.intervals[1].endedAt, origin.addingTimeInterval(30))
        }
    }

    func testDailyHistoryClipsIntervalsAtMidnightAndCalculatesTotals() throws {
        try withRepository { repository, _ in
            let day = utcCalendar.date(
                from: DateComponents(year: 2026, month: 9, day: 3)
            )!
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(
                state: engine.state,
                at: day.addingTimeInterval(-600)
            )
            try commit(
                .clockIn,
                at: day.addingTimeInterval(-600),
                engine: &engine,
                repository: repository
            )
            try commit(
                .startBreak,
                at: day.addingTimeInterval(600),
                engine: &engine,
                repository: repository
            )
            try commit(
                .returnToFocus,
                at: day.addingTimeInterval(1_200),
                engine: &engine,
                repository: repository
            )
            try commit(
                .clockOut,
                at: day.addingTimeInterval(1_800),
                engine: &engine,
                repository: repository
            )

            let history = try repository.dailyHistory(on: day, calendar: utcCalendar)
            let summary = history.summary(at: day.addingTimeInterval(3_600))

            XCTAssertEqual(history.sessions.count, 1)
            XCTAssertEqual(history.intervals.map(\.kind), [.focus, .breakTime, .focus])
            XCTAssertEqual(history.clippedStart(for: history.intervals[0]), day)
            XCTAssertEqual(summary.clockedIn, 1_800)
            XCTAssertEqual(summary.working, 1_200)
            XCTAssertEqual(summary.focus, 1_200)
            XCTAssertEqual(summary.breaks, 600)
            XCTAssertEqual(summary.meetings, 0)
        }
    }

    func testDailyHistoryUsesNowForOpenSessionAndInterval() throws {
        try withRepository { repository, _ in
            let day = utcCalendar.date(
                from: DateComponents(year: 2026, month: 9, day: 3)
            )!
            let clockIn = day.addingTimeInterval(9 * 3_600)
            let now = clockIn.addingTimeInterval(3_600)
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: clockIn)
            try commit(.clockIn, at: clockIn, engine: &engine, repository: repository)

            let history = try repository.dailyHistory(on: day, calendar: utcCalendar)
            let summary = history.summary(at: now)

            XCTAssertNil(history.sessions[0].endedAt)
            XCTAssertNil(history.intervals[0].endedAt)
            XCTAssertEqual(summary.clockedIn, 3_600)
            XCTAssertEqual(summary.focus, 3_600)
        }
    }

    func testDailyHistoryRollsOpenMeetingIntoNextLocalDay() throws {
        try withRepository { repository, _ in
            let day = utcCalendar.date(
                from: DateComponents(year: 2026, month: 9, day: 3)
            )!
            let nextDay = utcCalendar.date(byAdding: .day, value: 1, to: day)!
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: day)
            try commit(
                .clockIn,
                at: day.addingTimeInterval(23 * 3_600 + 50 * 60),
                engine: &engine,
                repository: repository
            )
            try commit(
                .startManualMeeting,
                at: day.addingTimeInterval(23 * 3_600 + 55 * 60),
                engine: &engine,
                repository: repository
            )

            let history = try repository.dailyHistory(
                on: nextDay.addingTimeInterval(10 * 60),
                calendar: utcCalendar
            )
            let summary = history.summary(at: nextDay.addingTimeInterval(10 * 60))

            XCTAssertFalse(history.contains(day.addingTimeInterval(23 * 3_600 + 59 * 60)))
            XCTAssertTrue(history.contains(nextDay))
            XCTAssertFalse(history.contains(history.day.end))
            XCTAssertEqual(history.intervals.map(\.kind), [.meeting])
            XCTAssertEqual(summary.clockedIn, 10 * 60)
            XCTAssertEqual(summary.meetings, 10 * 60)
            XCTAssertEqual(summary.focus, 0)
        }
    }

    func testCorrectingCompletedIntervalUpdatesAuditFieldsAndSummary() throws {
        try withRepository { repository, _ in
            let history = try createClosedCycle(in: repository)
            let interval = history.intervals[0]
            let correctedAt = origin.addingTimeInterval(200)

            try repository.correctInterval(
                id: interval.id,
                kind: .meeting,
                startedAt: origin.addingTimeInterval(5),
                endedAt: origin.addingTimeInterval(55),
                correctedAt: correctedAt
            )

            var corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(corrected.intervals[0].kind, .meeting)
            XCTAssertEqual(corrected.intervals[0].startedAt, origin.addingTimeInterval(5))
            XCTAssertEqual(corrected.intervals[0].endedAt, origin.addingTimeInterval(55))
            XCTAssertEqual(corrected.intervals[0].correctedFromKind, .focus)
            XCTAssertEqual(corrected.intervals[0].updatedAt, correctedAt)
            XCTAssertEqual(corrected.intervals[0].source, "state_machine")

            try repository.correctInterval(
                id: interval.id,
                kind: .lunch,
                startedAt: origin.addingTimeInterval(10),
                endedAt: origin.addingTimeInterval(50),
                correctedAt: correctedAt.addingTimeInterval(1)
            )
            corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            let summary = corrected.summary(at: correctedAt)
            XCTAssertEqual(corrected.intervals[0].correctedFromKind, .focus)
            XCTAssertEqual(summary.clockedIn, 120)
            XCTAssertEqual(summary.focus, 40)
            XCTAssertEqual(summary.meetings, 0)
            XCTAssertEqual(summary.breaks, 20)
            XCTAssertEqual(summary.lunch, 40)
        }
    }

    func testCorrectionRejectsOverlapAndRollsBack() throws {
        try withRepository { repository, _ in
            let history = try createClosedCycle(in: repository)
            let interval = history.intervals[0]

            XCTAssertThrowsError(
                try repository.correctInterval(
                    id: interval.id,
                    kind: .meeting,
                    startedAt: origin,
                    endedAt: origin.addingTimeInterval(70)
                )
            ) { error in
                XCTAssertEqual(
                    error as? SessionRepositoryError,
                    .correctionOverlapsExistingInterval
                )
            }

            let unchanged = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(unchanged.intervals[0], interval)
        }
    }

    func testCorrectionRejectsOpenIntervalAndInvalidSessionBounds() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let openInterval = try repository.dailyHistory(
                on: origin,
                calendar: utcCalendar
            ).intervals[0]

            XCTAssertThrowsError(
                try repository.correctInterval(
                    id: openInterval.id,
                    kind: .focus,
                    startedAt: origin,
                    endedAt: origin.addingTimeInterval(30)
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .cannotCorrectOpenInterval)
            }

            try commit(
                .clockOut,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )
            XCTAssertThrowsError(
                try repository.correctInterval(
                    id: openInterval.id,
                    kind: .focus,
                    startedAt: origin.addingTimeInterval(-1),
                    endedAt: origin.addingTimeInterval(30)
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .correctionOutsideSession)
            }
            XCTAssertThrowsError(
                try repository.correctInterval(
                    id: openInterval.id,
                    kind: .focus,
                    startedAt: origin.addingTimeInterval(30),
                    endedAt: origin.addingTimeInterval(30)
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .invalidCorrectionRange)
            }
        }
    }

    func testCorrectingWorkSessionUpdatesBoundaryIntervalsAndSummary() throws {
        try withRepository { repository, _ in
            let history = try createClosedCycle(in: repository)
            let session = history.sessions[0]
            let correctedAt = origin.addingTimeInterval(300)

            try repository.correctWorkSession(
                id: session.id,
                startedAt: origin.addingTimeInterval(10),
                endedAt: origin.addingTimeInterval(110),
                correctedAt: correctedAt
            )

            var corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(corrected.sessions[0].startedAt, origin.addingTimeInterval(10))
            XCTAssertEqual(corrected.sessions[0].endedAt, origin.addingTimeInterval(110))
            XCTAssertEqual(corrected.sessions[0].correctedFromStartedAt, origin)
            XCTAssertEqual(
                corrected.sessions[0].correctedFromEndedAt,
                origin.addingTimeInterval(120)
            )
            XCTAssertEqual(corrected.sessions[0].updatedAt, correctedAt)
            XCTAssertEqual(corrected.intervals[0].startedAt, origin.addingTimeInterval(10))
            XCTAssertEqual(corrected.intervals[2].endedAt, origin.addingTimeInterval(110))
            XCTAssertTrue(corrected.intervals[0].wasCorrected)
            XCTAssertTrue(corrected.intervals[2].wasCorrected)

            var summary = corrected.summary(at: correctedAt)
            XCTAssertEqual(summary.clockedIn, 100)
            XCTAssertEqual(summary.focus, 80)
            XCTAssertEqual(summary.breaks, 20)

            try repository.correctWorkSession(
                id: session.id,
                startedAt: origin.addingTimeInterval(5),
                endedAt: origin.addingTimeInterval(115),
                correctedAt: correctedAt.addingTimeInterval(1)
            )
            corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            summary = corrected.summary(at: correctedAt)
            XCTAssertEqual(corrected.sessions[0].correctedFromStartedAt, origin)
            XCTAssertEqual(
                corrected.sessions[0].correctedFromEndedAt,
                origin.addingTimeInterval(120)
            )
            XCTAssertEqual(summary.clockedIn, 110)
            XCTAssertEqual(summary.focus, 90)
        }
    }

    func testCorrectingSingleIntervalSessionUpdatesBothBoundaries() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .clockOut,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )
            let history = try repository.dailyHistory(on: origin, calendar: utcCalendar)

            try repository.correctWorkSession(
                id: history.sessions[0].id,
                startedAt: origin.addingTimeInterval(-10),
                endedAt: origin.addingTimeInterval(70)
            )

            let corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(corrected.sessions[0].startedAt, origin.addingTimeInterval(-10))
            XCTAssertEqual(corrected.sessions[0].endedAt, origin.addingTimeInterval(70))
            XCTAssertEqual(corrected.intervals[0].startedAt, origin.addingTimeInterval(-10))
            XCTAssertEqual(corrected.intervals[0].endedAt, origin.addingTimeInterval(70))
            XCTAssertEqual(corrected.summary(at: origin.addingTimeInterval(100)).focus, 80)
        }
    }

    func testWorkSessionCorrectionRejectsOpenInvalidAndExcludedActivity() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let openSession = try repository.dailyHistory(
                on: origin,
                calendar: utcCalendar
            ).sessions[0]

            XCTAssertThrowsError(
                try repository.correctWorkSession(
                    id: openSession.id,
                    startedAt: origin,
                    endedAt: origin.addingTimeInterval(30)
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .cannotCorrectOpenSession)
            }

            try commit(
                .clockOut,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )
            XCTAssertThrowsError(
                try repository.correctWorkSession(
                    id: openSession.id,
                    startedAt: origin.addingTimeInterval(30),
                    endedAt: origin.addingTimeInterval(30)
                )
            ) { error in
                XCTAssertEqual(error as? SessionRepositoryError, .invalidSessionCorrectionRange)
            }

            let beforeFutureCorrection = try repository.dailyHistory(
                on: origin,
                calendar: utcCalendar
            )
            XCTAssertThrowsError(
                try repository.correctWorkSession(
                    id: openSession.id,
                    startedAt: origin,
                    endedAt: origin.addingTimeInterval(101),
                    correctedAt: origin.addingTimeInterval(100)
                )
            ) { error in
                XCTAssertEqual(
                    error as? SessionRepositoryError,
                    .sessionCorrectionEndsInFuture
                )
            }
            XCTAssertEqual(
                try repository.dailyHistory(on: origin, calendar: utcCalendar),
                beforeFutureCorrection
            )
        }

        try withRepository { repository, _ in
            let history = try createClosedCycle(in: repository)
            XCTAssertThrowsError(
                try repository.correctWorkSession(
                    id: history.sessions[0].id,
                    startedAt: origin.addingTimeInterval(65),
                    endedAt: origin.addingTimeInterval(120)
                )
            ) { error in
                XCTAssertEqual(
                    error as? SessionRepositoryError,
                    .sessionCorrectionWouldInvalidateIntervals
                )
            }
        }
    }

    func testWorkSessionCorrectionRejectsOverlapAndRollsBack() throws {
        try withRepository { repository, _ in
            let firstHistory = try createClosedCycle(in: repository)
            var engine = BreakBarEngine(
                state: try XCTUnwrap(repository.loadState()),
                policy: policy
            )
            try commit(
                .clockIn,
                at: origin.addingTimeInterval(200),
                engine: &engine,
                repository: repository
            )
            try commit(
                .clockOut,
                at: origin.addingTimeInterval(260),
                engine: &engine,
                repository: repository
            )

            XCTAssertThrowsError(
                try repository.correctWorkSession(
                    id: firstHistory.sessions[0].id,
                    startedAt: origin,
                    endedAt: origin.addingTimeInterval(210)
                )
            ) { error in
                XCTAssertEqual(
                    error as? SessionRepositoryError,
                    .sessionCorrectionOverlapsExistingSession
                )
            }

            let unchanged = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(unchanged.sessions[0], firstHistory.sessions[0])
            XCTAssertEqual(unchanged.intervals[2], firstHistory.intervals[2])
        }
    }

    func testActiveClockInCorrectionUpdatesLedgerAndSavedCountdown() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let history = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            let session = history.sessions[0]
            XCTAssertTrue(
                try repository.isOpenWorkSessionInInitialFocusCycle(id: session.id)
            )
            let correctedStart = origin.addingTimeInterval(-20)
            let correctedAt = origin.addingTimeInterval(10)
            let previous = engine.state
            var candidate = engine
            XCTAssertEqual(
                candidate.handle(
                    .correctClockIn(
                        from: session.startedAt,
                        to: correctedStart,
                        adjustsCurrentFocusCycle: true
                    ),
                    at: correctedAt
                ),
                .changed
            )

            try repository.correctOpenWorkSessionStart(
                id: session.id,
                from: previous,
                to: candidate.state,
                startedAt: correctedStart,
                correctedAt: correctedAt
            )

            var corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(corrected.sessions[0].startedAt, correctedStart)
            XCTAssertNil(corrected.sessions[0].endedAt)
            XCTAssertEqual(corrected.sessions[0].correctedFromStartedAt, origin)
            XCTAssertNil(corrected.sessions[0].correctedFromEndedAt)
            XCTAssertEqual(corrected.intervals[0].startedAt, correctedStart)
            XCTAssertNil(corrected.intervals[0].endedAt)
            XCTAssertEqual(try repository.loadState(), candidate.state)
            XCTAssertEqual(
                candidate.state.focusDueAt,
                correctedStart.addingTimeInterval(policy.focusDuration)
            )

            let secondStart = origin.addingTimeInterval(-10)
            let secondPrevious = candidate.state
            XCTAssertEqual(
                candidate.handle(
                    .correctClockIn(
                        from: correctedStart,
                        to: secondStart,
                        adjustsCurrentFocusCycle: true
                    ),
                    at: correctedAt.addingTimeInterval(1)
                ),
                .changed
            )
            try repository.correctOpenWorkSessionStart(
                id: session.id,
                from: secondPrevious,
                to: candidate.state,
                startedAt: secondStart,
                correctedAt: correctedAt.addingTimeInterval(1)
            )
            corrected = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(corrected.sessions[0].correctedFromStartedAt, origin)
            XCTAssertTrue(
                try repository.isOpenWorkSessionInInitialFocusCycle(id: session.id)
            )
        }
    }

    func testOpenWorkSessionStopsBeingInitialCycleAfterBreak() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            let session = try XCTUnwrap(
                repository.dailyHistory(on: origin, calendar: utcCalendar).sessions.first
            )
            XCTAssertTrue(
                try repository.isOpenWorkSessionInInitialFocusCycle(id: session.id)
            )

            try commit(
                .startBreak,
                at: origin.addingTimeInterval(policy.focusDuration),
                engine: &engine,
                repository: repository
            )
            try commit(
                .returnToFocus,
                at: origin.addingTimeInterval(
                    policy.focusDuration + policy.minimumBreakDuration
                ),
                engine: &engine,
                repository: repository
            )

            XCTAssertFalse(
                try repository.isOpenWorkSessionInInitialFocusCycle(id: session.id)
            )
        }
    }

    func testActiveClockInCorrectionRejectsPreviousSessionOverlap() throws {
        try withRepository { repository, _ in
            var engine = BreakBarEngine(policy: policy)
            try repository.bootstrapIfNeeded(state: engine.state, at: origin)
            try commit(.clockIn, at: origin, engine: &engine, repository: repository)
            try commit(
                .clockOut,
                at: origin.addingTimeInterval(60),
                engine: &engine,
                repository: repository
            )
            try commit(
                .clockIn,
                at: origin.addingTimeInterval(100),
                engine: &engine,
                repository: repository
            )
            let before = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            let activeSession = try XCTUnwrap(before.sessions.last)
            let previous = engine.state
            var candidate = engine
            XCTAssertEqual(
                candidate.handle(
                    .correctClockIn(
                        from: activeSession.startedAt,
                        to: origin.addingTimeInterval(50),
                        adjustsCurrentFocusCycle: true
                    ),
                    at: origin.addingTimeInterval(110)
                ),
                .changed
            )

            XCTAssertThrowsError(
                try repository.correctOpenWorkSessionStart(
                    id: activeSession.id,
                    from: previous,
                    to: candidate.state,
                    startedAt: origin.addingTimeInterval(50),
                    correctedAt: origin.addingTimeInterval(110)
                )
            ) { error in
                XCTAssertEqual(
                    error as? SessionRepositoryError,
                    .sessionCorrectionOverlapsExistingSession
                )
            }

            let unchanged = try repository.dailyHistory(on: origin, calendar: utcCalendar)
            XCTAssertEqual(unchanged.sessions.last, activeSession)
            XCTAssertEqual(try repository.loadState(), previous)
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

    private func createClosedCycle(in repository: SessionRepository) throws -> DailyHistory {
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
            at: origin.addingTimeInterval(120),
            engine: &engine,
            repository: repository
        )
        return try repository.dailyHistory(on: origin, calendar: utcCalendar)
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

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
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
