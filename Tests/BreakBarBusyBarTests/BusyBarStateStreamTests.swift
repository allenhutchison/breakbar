import Foundation
import XCTest
@testable import BreakBarBusyBar

final class BusyBarStateStreamTests: XCTestCase {
    func testBuildsUnsecuredUSBWebSocketURL() throws {
        let stream = try BusyBarStateStream(
            baseURL: try XCTUnwrap(URL(string: "http://10.0.4.20"))
        )

        XCTAssertEqual(stream.socketURL.absoluteString, "ws://10.0.4.20/api/status/ws")
    }

    func testBuildsSecureAuthenticatedWebSocketURL() throws {
        let stream = try BusyBarStateStream(
            baseURL: try XCTUnwrap(URL(string: "https://busybar.local:8443")),
            apiToken: "token with spaces"
        )

        XCTAssertEqual(stream.socketURL.scheme, "wss")
        XCTAssertEqual(stream.socketURL.host, "busybar.local")
        XCTAssertEqual(stream.socketURL.port, 8443)
        XCTAssertEqual(stream.socketURL.path, "/api/status/ws")
        XCTAssertEqual(
            URLComponents(url: stream.socketURL, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "x-api-token", value: "token with spaces")]
        )
    }

    func testRejectsNonHTTPBaseURL() throws {
        XCTAssertThrowsError(
            try BusyBarStateStream(
                baseURL: XCTUnwrap(URL(string: "file:///tmp/busybar"))
            )
        ) { error in
            XCTAssertEqual(error as? BusyBarStateStreamError, .invalidBaseURL)
        }
    }

    func testRejectsBaseURLWithEndpointPath() throws {
        XCTAssertThrowsError(
            try BusyBarStateStream(
                baseURL: XCTUnwrap(URL(string: "http://busybar.local/proxy"))
            )
        ) { error in
            XCTAssertEqual(error as? BusyBarStateStreamError, .invalidBaseURL)
        }
    }
}
