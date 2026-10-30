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
        let model = AppModel(configuration: configuration)
        XCTAssertEqual(model.observeActivity(idleDuration: 30, at: due.addingTimeInterval(30)), .changed)
        XCTAssertEqual(model.state.phase, .onBreak)
        XCTAssertEqual(model.state.phaseStartedAt, due)
        XCTAssertEqual(try repository.loadState(), model.state)

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
