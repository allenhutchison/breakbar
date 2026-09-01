import BreakBarCore
@testable import BreakBarPersistence
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
}
