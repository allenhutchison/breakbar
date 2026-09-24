import Foundation
import XCTest

final class SettingsPrivacyUITests: XCTestCase {
    @MainActor
    func testPreviousDayTravelOffersPriorSessionClockOut() throws {
        let appURL = ProcessInfo.processInfo.environment["BREAKBAR_UI_TEST_APP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultAppURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

        let application = XCUIApplication(url: appURL)
        application.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--ui-test",
            "--ui-test-scenario", "overnight-travel-correction",
            "--ui-test-database", testDirectory.appendingPathComponent("breakbar.sqlite").path,
        ]
        application.launch()
        defer {
            application.terminate()
            try? FileManager.default.removeItem(at: testDirectory)
        }
        continueAfterFailure = false

        let historyWindow = application.windows["History"]
        XCTAssertTrue(historyWindow.waitForExistence(timeout: 5))
        historyWindow.buttons["Previous day"].click()

        let travelRow = historyWindow.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "history.interval.travel.")
        ).firstMatch
        XCTAssertTrue(travelRow.waitForExistence(timeout: 3))
        for _ in 0 ..< 8 where !travelRow.isHittable {
            historyWindow.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(travelRow.isHittable)
        travelRow.click()

        let clockOutPicker = historyWindow.datePickers["history.travel-clock-out-picker"]
        XCTAssertTrue(clockOutPicker.waitForExistence(timeout: 3))
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let calendar = Calendar.current
        for (position, value) in [
            (0.06, String(calendar.component(.month, from: yesterday))),
            (0.17, String(calendar.component(.day, from: yesterday))),
            (0.34, String(calendar.component(.year, from: yesterday))),
            (0.57, "9"),
            (0.68, "00"),
            (0.81, "PM"),
        ] {
            clockOutPicker.coordinate(
                withNormalizedOffset: CGVector(dx: position, dy: 0.5)
            ).click()
            clockOutPicker.typeText(value)
        }
        historyWindow.staticTexts["Forgot to clock out after travel?"].click()

        let clockOutButton = historyWindow.buttons["End previous work session"]
        XCTAssertTrue(clockOutButton.isEnabled, historyWindow.debugDescription)
        clockOutButton.click()
        XCTAssertTrue(
            historyWindow.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Travel,' AND label CONTAINS '1 hours'")
            ).firstMatch.waitForExistence(timeout: 5),
            historyWindow.debugDescription
        )
    }

    @MainActor
    func testAwayReturnOffersMeetingClassification() throws {
        let appURL = ProcessInfo.processInfo.environment["BREAKBAR_UI_TEST_APP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultAppURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakBarUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

        let application = XCUIApplication(url: appURL)
        application.launchArguments = [
            "--ui-test",
            "--ui-test-scenario", "away-classification",
            "--ui-test-database", testDirectory.appendingPathComponent("breakbar.sqlite").path,
        ]
        application.launch()
        defer {
            application.terminate()
            try? FileManager.default.removeItem(at: testDirectory)
        }
        continueAfterFailure = false

        let meetingButton = application.buttons["Meeting"]
        XCTAssertTrue(meetingButton.waitForExistence(timeout: 5))
        XCTAssertTrue(meetingButton.isHittable)
        meetingButton.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: meetingButton)
        waitForExpectations(timeout: 5)

        let historyWindow = application.windows["History"]
        XCTAssertTrue(historyWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            historyWindow.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Meetings, 1 minutes'"))
                .firstMatch
                .waitForExistence(timeout: 5),
            historyWindow.debugDescription
        )
        XCTAssertTrue(
            historyWindow.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Meeting,'"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )
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
