import Foundation
import XCTest
@testable import BreakBarApp

final class AppLaunchConfigurationTests: XCTestCase {
    func testStandardAndDemoModesDoNotOverrideTheDatabase() {
        XCTAssertEqual(
            AppLaunchConfiguration.parse(arguments: ["BreakBar"]),
            AppLaunchConfiguration(mode: .standard, databaseURL: nil)
        )
        XCTAssertEqual(
            AppLaunchConfiguration.parse(arguments: ["BreakBar", "--demo"]),
            AppLaunchConfiguration(mode: .demo, databaseURL: nil)
        )
    }

    func testUITestModeUsesRequestedTemporaryDatabaseAndScenario() {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppLaunchConfigurationTests", isDirectory: true)
        let databaseURL = temporaryDirectory.appendingPathComponent("history.sqlite")

        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "BreakBar",
                "--demo",
                "--ui-test",
                "--ui-test-scenario", "settings-privacy",
                "--ui-test-database", databaseURL.path,
            ],
            temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        XCTAssertEqual(configuration.mode, .uiTest(.settingsPrivacy))
        XCTAssertEqual(configuration.databaseURL, databaseURL.standardizedFileURL)
        XCTAssertEqual(configuration.referenceDate, AppLaunchConfiguration.uiTestReferenceDate)
        XCTAssertFalse(configuration.isDemoMode)
        XCTAssertTrue(configuration.isUITestMode)
    }

    func testUITestModeRejectsDatabaseOutsideTemporaryDirectory() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "BreakBar",
                "--ui-test",
                "--ui-test-database", "/Users/example/Library/Application Support/BreakBar/breakbar.sqlite",
            ],
            temporaryDirectory: temporaryDirectory
        )

        let databaseURL = try XCTUnwrap(configuration.databaseURL)
        XCTAssertTrue(databaseURL.path.hasPrefix(temporaryDirectory.standardizedFileURL.path + "/"))
        XCTAssertEqual(databaseURL.pathExtension, "sqlite")
        XCTAssertEqual(databaseURL.deletingLastPathComponent(), temporaryDirectory.standardizedFileURL)
        XCTAssertNotEqual(
            databaseURL.path,
            "/Users/example/Library/Application Support/BreakBar/breakbar.sqlite"
        )
    }
}
