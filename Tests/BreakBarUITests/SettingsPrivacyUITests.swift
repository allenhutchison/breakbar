import Foundation
import XCTest

final class SettingsPrivacyUITests: XCTestCase {
    @MainActor
    func testAutomaticTimerHasPauseAndResumeWithoutTrackingControls() throws {
        let application = XCUIApplication(url: Self.defaultAppURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        application.launchArguments = [
            "--ui-test", "--ui-test-scenario", "automatic-timer",
            "--ui-test-database", directory.appendingPathComponent("timer.sqlite").path,
        ]
        application.launch()
        defer {
            application.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        continueAfterFailure = false
        let statusItem = application.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let pause = application.buttons["timer.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), application.debugDescription)
        XCTAssertFalse(application.buttons["Clock in"].exists)
        XCTAssertFalse(application.buttons["Clock out"].exists)
        XCTAssertFalse(application.buttons["Take lunch"].exists)
        XCTAssertFalse(application.buttons["Today’s history"].exists)
        pause.click()
        let resume = application.buttons["timer.primary"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        XCTAssertEqual(resume.label, "Resume reminders")
        XCTAssertTrue(application.staticTexts["Reminders paused"].exists)
        resume.click()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
    }

    @MainActor
    func testSettingsPrivacyExplanationAndDeletionFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let appURL = environment["BREAKBAR_UI_TEST_APP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultAppURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appURL.path),
            "Run `make test-ui` first so the isolated app bundle is available at \(appURL.path)."
        )

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )

        let application = XCUIApplication(url: appURL)
        application.launchArguments = [
            "--ui-test",
            "--ui-test-scenario", "settings-privacy",
            "--ui-test-database", testDirectory.appendingPathComponent("breakbar.sqlite").path,
        ]
        application.launch()
        defer {
            application.terminate()
            try? FileManager.default.removeItem(at: testDirectory)
        }
        continueAfterFailure = false

        XCTAssertTrue(
            application.windows["BreakBar Settings"].waitForExistence(timeout: 5),
            "The UI-test launch profile should open Settings without onboarding."
        )

        XCTAssertTrue(
            application.staticTexts["settings.privacy.explanation"]
                .waitForExistence(timeout: 2)
        )

        let exportButton = application.buttons["settings.privacy.export-history"]
        XCTAssertTrue(exportButton.exists)
        XCTAssertTrue(exportButton.isEnabled)

        let deleteButton = application.buttons["settings.privacy.delete-history"]
        XCTAssertTrue(deleteButton.exists)
        XCTAssertTrue(deleteButton.isEnabled)
        scrollUntilHittable(deleteButton, in: application)
        XCTAssertTrue(deleteButton.isHittable)
        deleteButton.click()

        let confirmationSheet = application.windows["BreakBar Settings"].sheets.firstMatch
        XCTAssertTrue(confirmationSheet.waitForExistence(timeout: 2))
        XCTAssertTrue(
            confirmationSheet.staticTexts["Delete all local history?"].exists
        )
        confirmationSheet.buttons["Delete History"].click()

        let status = application.descendants(matching: .any)["settings.privacy.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(status.label.contains("Deleted all local history"))
        XCTAssertFalse(application.staticTexts["Obsidian"].exists)
        let window = application.windows["BreakBar Settings"]
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(window.exists)
        XCTAssertNotEqual(application.state, .notRunning)
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in application: XCUIApplication
    ) {
        let scrollView = application.scrollViews.firstMatch
        for _ in 0 ..< 8 where !element.isHittable {
            scrollView.swipeUp()
        }
    }

    private static var defaultAppURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/BreakBarUITest.app", isDirectory: true)
    }
}
