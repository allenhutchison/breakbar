import Foundation
import XCTest
@testable import BreakBarCore

final class PausedReturnTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testLongIdlePromptsOnceAndKeepPausedRequiresAnotherAbsence() {
        var engine = BreakBarEngine()
        _ = engine.handle(.pauseReminders, at: origin)
        for idle in [0.0, 599, -1, .infinity, .nan] {
            XCTAssertEqual(engine.handle(.observeActivity(idleDuration: idle), at: origin), .unchanged)
        }
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 600), at: origin), .changed)
        XCTAssertNil(engine.state.pausedReturnPromptAt)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 601), at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 2), at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin), .changed)
        XCTAssertNotNil(engine.state.pausedReturnPromptAt)
        XCTAssertEqual(engine.state.remindersPaused, true)
        XCTAssertEqual(engine.state.phase, .clockedOut)
        XCTAssertNil(engine.state.focusDueAt)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.keepRemindersPaused, at: origin), .changed)
        XCTAssertNil(engine.state.pausedReturnPromptAt)
        XCTAssertEqual(engine.handle(.keepRemindersPaused, at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 600), at: origin), .changed)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin), .changed)
        let returnedAt = origin.addingTimeInterval(1000)
        XCTAssertEqual(engine.handle(.resumeReminders, at: returnedAt), .changed)
        XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(BreakPolicy.standard.focusDuration))
        XCTAssertNil(engine.state.pausedIdleObservedAt)
        XCTAssertNil(engine.state.pausedReturnPromptAt)
        XCTAssertEqual(engine.state.remindersPaused, false)
        XCTAssertEqual(engine.handle(.keepRemindersPaused, at: returnedAt), .unchanged)
    }

    func testLongSleepPromptsOnActivityAndShortSleepStaysQuiet() throws {
        var engine = BreakBarEngine()
        XCTAssertEqual(engine.handle(.systemWillSleep, at: origin), .unchanged)
        _ = engine.handle(.pauseReminders, at: origin)
        _ = engine.handle(.systemWillSleep, at: origin)
        XCTAssertEqual(engine.handle(.systemWillSleep, at: origin), .unchanged)
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(599)), .changed)
        XCTAssertNil(engine.state.pausedReturnPromptAt)
        XCTAssertNil(engine.state.pausedSleepStartedAt)
        _ = engine.handle(.systemWillSleep, at: origin.addingTimeInterval(600))
        // Sleep evidence must survive restart before the next activity sample.
        let saved = try JSONEncoder().encode(engine.state)
        engine = BreakBarEngine(state: try JSONDecoder().decode(BreakBarState.self, from: saved))
        XCTAssertEqual(engine.handle(.observeActivity(idleDuration: 0), at: origin.addingTimeInterval(1200)), .changed)
        XCTAssertNotNil(engine.state.pausedReturnPromptAt)
        XCTAssertEqual(engine.state.remindersPaused, true)
    }

    func testLegacyPausedSnapshotDecodesWithoutPrompt() throws {
        let data = Data(#"{"phase":"clockedOut","enforcement":"none","remindersPaused":true,"revision":1}"#.utf8)
        let restored = try JSONDecoder().decode(BreakBarState.self, from: data)
        XCTAssertNil(restored.pausedIdleObservedAt)
        XCTAssertNil(restored.pausedReturnPromptAt)
        XCTAssertNil(restored.pausedSleepStartedAt)
    }
}
