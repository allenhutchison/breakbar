import BreakBarCore
import BreakBarPersistence
import Foundation
import XCTest

final class AutomaticTimerPersistenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testTimerOnlyCycleRecoversWithoutRecordingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timer.sqlite")
        let repository = try SessionRepository(url: url)
        var engine = BreakBarEngine()
        try repository.prepareAutomaticTimer(state: engine.state, at: origin)
        for (command, offset): (BreakCommand, Double) in [
            (.observeActivity(idleDuration: 0), 0), (.startBreak, 60),
            (.returnToFocus, 400), (.pauseReminders, 500),
            (.observeActivity(idleDuration: 600), 1100),
        ] {
            let previous = engine.state
            XCTAssertEqual(engine.handle(command, at: origin.addingTimeInterval(offset)), .changed)
            try repository.commitTimerTransition(from: previous, to: engine.state)
        }
        let recovered = try SessionRepository(url: url)
        var restoredEngine = BreakBarEngine(state: try XCTUnwrap(recovered.loadState()))
        let beforeReturn = restoredEngine.state
        XCTAssertEqual(restoredEngine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(1200)), .changed)
        XCTAssertNotNil(restoredEngine.state.pausedReturnPromptAt)
        try recovered.commitTimerTransition(from: beforeReturn, to: restoredEngine.state)
        engine = restoredEngine
        let reopened = try SessionRepository(url: url)
        XCTAssertEqual(try reopened.loadState(), engine.state)
        XCTAssertEqual(try reopened.loadState()?.remindersPaused, true)
        let archive = try reopened.completeHistory(exportedAt: origin.addingTimeInterval(600))
        XCTAssertTrue(archive.sessions.isEmpty)
        XCTAssertTrue(archive.intervals.isEmpty)
        XCTAssertThrowsError(try reopened.commitTimerTransition(from: BreakBarState(), to: engine.state)) {
            XCTAssertEqual($0 as? SessionRepositoryError, .staleState)
        }
    }

    func testUpgradeFreezesLegacyHistoryAndKeepsTimerDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SessionRepository(url: directory.appendingPathComponent("legacy.sqlite"))
        var engine = BreakBarEngine()
        try repository.bootstrapIfNeeded(state: engine.state, at: origin)
        let previous = engine.state
        _ = engine.handle(.clockIn, at: origin)
        try repository.commitTransition(from: previous, to: engine.state, at: origin)
        let frozenAt = origin.addingTimeInterval(100)
        try repository.prepareAutomaticTimer(state: BreakBarState(), at: frozenAt)
        XCTAssertEqual(try repository.loadState(), engine.state)
        let frozen = try repository.completeHistory(exportedAt: frozenAt)
        XCTAssertEqual(frozen.sessions.count, 1)
        XCTAssertEqual(frozen.sessions.first?.endedAt, frozenAt)
        XCTAssertEqual(frozen.intervals.first?.endedAt, frozenAt)
        let beforePause = engine.state
        _ = engine.handle(.pauseReminders, at: origin.addingTimeInterval(200))
        try repository.commitTimerTransition(from: beforePause, to: engine.state)
        try repository.prepareAutomaticTimer(state: BreakBarState(), at: origin.addingTimeInterval(300))
        let after = try repository.completeHistory(exportedAt: frozenAt)
        XCTAssertEqual(after.sessions, frozen.sessions)
        XCTAssertEqual(after.intervals, frozen.intervals)
    }
}
