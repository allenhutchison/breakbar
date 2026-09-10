import Foundation
import XCTest

final class CalendarPermissionConfigurationTests: XCTestCase {
    func testBundleDeclaresCalendarPermissionRequirements() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let entitlements = try propertyList(
            at: repositoryRoot.appendingPathComponent("Support/BreakBar.entitlements")
        )
        XCTAssertEqual(
            entitlements["com.apple.security.personal-information.calendars"] as? Bool,
            true
        )

        let info = try propertyList(
            at: repositoryRoot.appendingPathComponent("Support/Info.plist")
        )
        XCTAssertFalse(
            try XCTUnwrap(info["NSCalendarsFullAccessUsageDescription"] as? String).isEmpty
        )
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
