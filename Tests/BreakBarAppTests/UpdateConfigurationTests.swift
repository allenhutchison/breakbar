import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testBundleDeclaresSignedAutomaticUpdateChannel() throws {
        let info = try propertyList(
            at: repositoryRoot.appendingPathComponent("Support/Info.plist")
        )

        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)

        let feedURL = try XCTUnwrap(
            URL(string: try XCTUnwrap(info["SUFeedURL"] as? String))
        )
        XCTAssertEqual(feedURL.scheme, "https")
        XCTAssertEqual(feedURL.host, "github.com")
        XCTAssertEqual(
            feedURL.path,
            "/allenhutchison/breakbar/releases/latest/download/appcast.xml"
        )

        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
    }

    func testReleaseWorkflowPublishesAppcastUsingPrivateKeySecret() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("secrets.SPARKLE_EDDSA_PRIVATE_KEY"))
        XCTAssertTrue(workflow.contains(".build/release/appcast.xml"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
