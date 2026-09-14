import Foundation
import XCTest
@testable import BreakBarBusyBar

final class BusyBarHTTPClientTests: XCTestCase {
    func testReadsAPIVersion() async throws {
        let transport = RecordingTransport(
            statusCode: 200,
            data: Data(#"{"api_semver":"27.5.0"}"#.utf8)
        )
        let client = try BusyBarHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "http://busybar.local")),
            transport: transport
        )

        let version = try await client.apiVersion()

        XCTAssertEqual(version, BusyBarAPIVersion(semanticVersion: "27.5.0"))
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/version")
        XCTAssertEqual(request.timeoutInterval, 5)
    }

    func testDrawsNamespacedSelfClearingFrontText() async throws {
        let transport = RecordingTransport(statusCode: 200)
        let client = try BusyBarHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "http://busybar.local")),
            apiToken: "secret-token",
            transport: transport
        )

        try await client.drawFrontText("BUSY 42m", timeoutSeconds: 3)

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/display/draw")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Token"), "secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["application_name"] as? String, "breakbar")
        XCTAssertEqual(json["priority"] as? Int, 50)

        let elements = try XCTUnwrap(json["elements"] as? [[String: Any]])
        let element = try XCTUnwrap(elements.first)
        XCTAssertEqual(element["id"] as? String, "status")
        XCTAssertEqual(element["type"] as? String, "text")
        XCTAssertEqual(element["text"] as? String, "BUSY 42m")
        XCTAssertEqual(element["timeout"] as? Int, 3)
        XCTAssertEqual(element["display"] as? String, "front")
        XCTAssertEqual(element["align"] as? String, "center")
        XCTAssertEqual(element["x"] as? Int, 36)
        XCTAssertEqual(element["y"] as? Int, 8)
    }

    func testRejectsPersistentOrNonASCIIText() async throws {
        let transport = RecordingTransport(statusCode: 200)
        let client = try BusyBarHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "http://busybar.local")),
            transport: transport
        )

        do {
            try await client.drawFrontText("BUSY", timeoutSeconds: 0)
            XCTFail("Expected timeout validation to fail")
        } catch {
            XCTAssertEqual(error as? BusyBarHTTPError, .invalidTimeout)
        }

        do {
            try await client.drawFrontText("BUSY •", timeoutSeconds: 3)
            XCTFail("Expected text validation to fail")
        } catch {
            XCTAssertEqual(error as? BusyBarHTTPError, .invalidText)
        }

        let capturedRequest = await transport.lastRequest()
        XCTAssertNil(capturedRequest)
    }

    func testClearsOnlyBreakBarElements() async throws {
        let transport = RecordingTransport(statusCode: 200)
        let client = try BusyBarHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "http://busybar.local")),
            transport: transport
        )

        try await client.clearOwnedDisplay()

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/display/draw")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems,
            [URLQueryItem(name: "application_name", value: "breakbar")]
        )
    }

    func testReportsHTTPStatusWithoutIncludingResponseBody() async throws {
        let transport = RecordingTransport(
            statusCode: 409,
            data: Data(#"{"error":"Not drawn due to low priority"}"#.utf8)
        )
        let client = try BusyBarHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "http://busybar.local")),
            transport: transport
        )

        do {
            try await client.drawFrontText("BUSY", timeoutSeconds: 3)
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? BusyBarHTTPError, .unexpectedStatus(409))
        }
    }
}

private actor RecordingTransport: BusyBarHTTPTransport {
    private let statusCode: Int
    private let data: Data
    private var requests: [URLRequest] = []

    init(statusCode: Int, data: Data = Data(#"{"result":"OK"}"#.utf8)) {
        self.statusCode = statusCode
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )
        )
        return (data, response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}
