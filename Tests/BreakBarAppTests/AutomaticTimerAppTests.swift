import BreakBarCore
import BreakBarPersistence
import Foundation
import XCTest
@testable import BreakBarApp

final class AutomaticTimerAppTests: XCTestCase {
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
