import Foundation
import XCTest

final class AccessoryPermissionConfigurationTests: XCTestCase {
    func testBundleExplainsOptionalLocalAccessoryConnection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Support/Info.plist")
        )
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertFalse(
            try XCTUnwrap(info["NSLocalNetworkUsageDescription"] as? String).isEmpty
        )
    }
}
