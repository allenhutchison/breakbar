import BreakBarCore
import BreakBarPersistence
import Foundation
import XCTest
@testable import BreakBarApp

final class AutomaticTimerAppTests: XCTestCase {
    @MainActor
    func testLeavingRequiredPromptPersistsCreditedBreakAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("timer.sqlite")
        let date = AppLaunchConfiguration.uiTestReferenceDate
        let repository = try SessionRepository(url: database)
        var engine = BreakBarEngine()
        _ = engine.handle(.resumeReminders, at: date)
        let due = date.addingTimeInterval(engine.policy.focusDuration)
        _ = engine.handle(.tick, at: due)
        try repository.prepareAutomaticTimer(state: engine.state, at: due)
        let configuration = AppLaunchConfiguration(mode: .uiTest(.settingsPrivacy), databaseURL: database)
        var breakActionStates: [BreakBarState] = []
        let model = AppModel(configuration: configuration, breakStartActions: {
            // Observe the real database at the OS-action boundary.
            if let saved = try? repository.loadState() {
                breakActionStates.append(saved)
            }
            return "Synthetic media-control failure"
        })
        XCTAssertEqual(model.observeActivity(idleDuration: 30, at: due.addingTimeInterval(30)), .changed)
        XCTAssertEqual(model.state.phase, .onBreak)
        XCTAssertEqual(model.state.phaseStartedAt, due)
        XCTAssertEqual(try repository.loadState(), model.state)
        XCTAssertEqual(breakActionStates, [model.state])
        XCTAssertEqual(model.lastMessage, "Synthetic media-control failure")
        XCTAssertEqual(model.observeActivity(idleDuration: 31, at: due.addingTimeInterval(31)), .unchanged)
        model.startBreak()
        XCTAssertEqual(breakActionStates.count, 1)

        let reopened = AppModel(configuration: configuration)
        XCTAssertEqual(reopened.state, model.state)
        let minimumEnd = try XCTUnwrap(reopened.state.minimumBreakEndsAt)
        XCTAssertEqual(reopened.observeActivity(idleDuration: 0, at: minimumEnd.addingTimeInterval(-1)), .rejected(remaining: 1))
        XCTAssertEqual(reopened.observeActivity(idleDuration: 0, at: minimumEnd), .changed)
        XCTAssertEqual(reopened.state.focusDueAt, minimumEnd.addingTimeInterval(reopened.policy.focusDuration))
        XCTAssertEqual(try repository.loadState(), reopened.state)
        let archive = try repository.completeHistory(exportedAt: minimumEnd)
        XCTAssertTrue(archive.sessions.isEmpty)
        XCTAssertTrue(archive.intervals.isEmpty)
    }

    @MainActor
    func testBreakActionsWaitForSuccessfulSaveAndRunOnceForButtonStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("timer.sqlite")
        let date = AppLaunchConfiguration.uiTestReferenceDate
        let repository = try SessionRepository(url: database)
        var engine = BreakBarEngine()
        _ = engine.handle(.resumeReminders, at: date)
        let due = date.addingTimeInterval(engine.policy.focusDuration)
        _ = engine.handle(.tick, at: due)
        try repository.prepareAutomaticTimer(state: engine.state, at: due)
        let configuration = AppLaunchConfiguration(mode: .uiTest(.settingsPrivacy), databaseURL: database)
        var actionCount = 0
        let staleModel = AppModel(configuration: configuration, breakStartActions: {
            actionCount += 1
            return nil
        })
        let model = AppModel(configuration: configuration, breakStartActions: {
            actionCount += 1
            XCTAssertEqual(try? repository.loadState()?.phase, .onBreak)
            return nil
        })
        model.startBreak()
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(model.state.phase, .onBreak)
        model.startBreak()
        XCTAssertEqual(actionCount, 1)
        // Another writer advanced the revision, so this save must fail.
        XCTAssertEqual(staleModel.observeActivity(idleDuration: 30, at: due.addingTimeInterval(30)), .unchanged)
        XCTAssertEqual(staleModel.state.phase, .focusing)
        XCTAssertNotNil(staleModel.lastMessage)
        XCTAssertEqual(actionCount, 1)
    }

    @MainActor
    func testActivityUsesDurableTimerPathAndPauseSurvivesAppRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("timer.sqlite")
        let configuration = AppLaunchConfiguration(mode: .uiTest(.settingsPrivacy), databaseURL: database)
        let date = AppLaunchConfiguration.uiTestReferenceDate
        let model = AppModel(configuration: configuration)
        XCTAssertEqual(model.observeActivity(idleDuration: 0, at: date), .changed)
        XCTAssertEqual(model.state.phase, .focusing)
        let repository = try SessionRepository(url: database)
        XCTAssertEqual(try repository.loadState(), model.state)
        model.pauseReminders()
        let reopened = AppModel(configuration: configuration)
        XCTAssertEqual(reopened.observeActivity(idleDuration: 0, at: date), .unchanged)
        XCTAssertEqual(reopened.presentation.title, "Reminders paused")
        reopened.resumeReminders()
        XCTAssertEqual(reopened.state.phase, .focusing)
        let archive = try repository.completeHistory(exportedAt: date)
        XCTAssertTrue(archive.sessions.isEmpty)
        XCTAssertTrue(archive.intervals.isEmpty)
    }
}
