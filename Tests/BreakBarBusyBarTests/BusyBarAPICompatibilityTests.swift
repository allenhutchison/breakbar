import XCTest
@testable import BreakBarBusyBar

final class BusyBarAPICompatibilityTests: XCTestCase {
    func testAcceptsSameMajorAndEqualOrNewerMinor() throws {
        XCTAssertNoThrow(
            try BusyBarAPICompatibility(
                clientVersion: "27.5.0",
                deviceVersion: "27.5.99-beta"
            )
        )
        XCTAssertNoThrow(
            try BusyBarAPICompatibility(
                clientVersion: "27.5.0",
                deviceVersion: "27.6.0"
            )
        )
    }

    func testRejectsOlderDeviceAPI() {
        XCTAssertThrowsError(
            try BusyBarAPICompatibility(
                clientVersion: "27.5.0",
                deviceVersion: "27.4.99"
            )
        ) { error in
            XCTAssertEqual(
                error as? BusyBarHTTPError,
                .incompatibleAPIVersion(client: "27.5.0", device: "27.4.99")
            )
        }
    }

    func testRejectsDifferentMajorAPIInEitherDirection() {
        for deviceVersion in ["26.99.0", "28.0.0"] {
            XCTAssertThrowsError(
                try BusyBarAPICompatibility(
                    clientVersion: "27.5.0",
                    deviceVersion: deviceVersion
                )
            ) { error in
                XCTAssertEqual(
                    error as? BusyBarHTTPError,
                    .incompatibleAPIVersion(client: "27.5.0", device: deviceVersion)
                )
            }
        }
    }

    func testRejectsMalformedVersions() {
        for version in ["", "27", "busy"] {
            XCTAssertThrowsError(
                try BusyBarAPICompatibility(
                    clientVersion: "27.5.0",
                    deviceVersion: version
                )
            ) { error in
                XCTAssertEqual(error as? BusyBarHTTPError, .invalidAPIVersion(version))
            }
        }
    }
}
