import Foundation
import XCTest
@testable import BreakBarBusyBar

final class BusyBarHardwareAcceptanceTests: XCTestCase {
    func testPhysicalInputsOverUSB() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["BREAKBAR_BUSYBAR_ACCEPTANCE"] == "1",
            "Set BREAKBAR_BUSYBAR_ACCEPTANCE=1 to run against connected hardware."
        )

        let baseURL = try XCTUnwrap(
            URL(string: environment["BREAKBAR_BUSYBAR_URL"] ?? "http://10.0.4.20")
        )
        let apiToken = environment["BREAKBAR_BUSYBAR_API_TOKEN"]
        let client = try BusyBarHTTPClient(baseURL: baseURL, apiToken: apiToken)
        _ = try await client.verifyCompatibility()

        let socketURL = try makeSocketURL(baseURL: baseURL, apiToken: apiToken)
        let opened = expectation(description: "BUSY Bar WebSocket opened")
        let delegate = HardwareWebSocketDelegate(opened: opened)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        let socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        await fulfillment(of: [opened], timeout: 5)
        try await socket.send(.string(#"{"enable":true}"#))

        let collector = HardwareInputCollector()
        let streamStarted = expectation(description: "BUSY Bar sent a binary state frame")
        let listener = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case .data(let data) = message else {
                        continue
                    }

                    if await collector.recordFrame() {
                        streamStarted.fulfill()
                    }
                    let events = try BusyBarStateDecoder.decodeInputEvents(from: data)
                    await collector.record(events)
                }
            } catch {
                await collector.recordFailure(String(describing: type(of: error)))
            }
        }

        await fulfillment(of: [streamStarted], timeout: 5)
        guard await collector.hasFrame else {
            listener.cancel()
            return
        }

        try await forwardInputKeys(
            ["ok", "back", "start", "up", "down"],
            baseURL: baseURL,
            apiToken: apiToken
        )
        let automaticResult = await waitForResult(
            collector,
            timeout: .seconds(5),
            isComplete: \HardwareInputResult.automaticIsComplete
        )
        XCTAssertTrue(
            automaticResult.automaticIsComplete,
            "Forwarded input observed only: \(automaticResult.summary)"
        )
        guard automaticResult.automaticIsComplete else {
            listener.cancel()
            return
        }

        await collector.resetInputs()
        FileHandle.standardError.write(Data("BUSYBAR_ACCEPTANCE_READY\n".utf8))
        let result = await waitForResult(
            collector,
            timeout: .seconds(90),
            isComplete: \HardwareInputResult.physicalIsComplete
        )
        listener.cancel()

        XCTAssertNil(result.failureType, "WebSocket failed with \(result.failureType ?? "unknown error")")
        XCTAssertTrue(result.physicalIsComplete, "Observed only: \(result.summary)")
    }

    private func makeSocketURL(baseURL: URL, apiToken: String?) throws -> URL {
        var components = try XCTUnwrap(
            URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        )
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/status/ws"
        if let apiToken {
            components.queryItems = [
                URLQueryItem(name: "x-api-token", value: apiToken)
            ]
        }
        return try XCTUnwrap(components.url)
    }

    private func forwardInputKeys(
        _ keys: [String],
        baseURL: URL,
        apiToken: String?
    ) async throws {
        for key in keys {
            var components = try XCTUnwrap(
                URLComponents(
                    url: baseURL.appendingPathComponent("api/input"),
                    resolvingAgainstBaseURL: false
                )
            )
            components.queryItems = [URLQueryItem(name: "key", value: key)]

            var request = URLRequest(url: try XCTUnwrap(components.url))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue(
                BusyBarAPICompatibility.clientVersion,
                forHTTPHeaderField: "X-Busy-Api-Version"
            )
            if let apiToken {
                request.setValue(apiToken, forHTTPHeaderField: "X-API-Token")
            }

            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertTrue(200 ..< 300 ~= httpResponse.statusCode)
            try await Task.sleep(for: .milliseconds(350))
        }
    }

    private func waitForResult(
        _ collector: HardwareInputCollector,
        timeout: Duration,
        isComplete: KeyPath<HardwareInputResult, Bool>
    ) async -> HardwareInputResult {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var result = await collector.result()
        while !result[keyPath: isComplete], ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            result = await collector.result()
        }
        return result
    }
}

private final class HardwareWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private let opened: XCTestExpectation

    init(opened: XCTestExpectation) {
        self.opened = opened
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        opened.fulfill()
    }
}

private actor HardwareInputCollector {
    private var buttons: Set<String> = []
    private var selectors: Set<String> = []
    private var sawClockwise = false
    private var sawCounterclockwise = false
    private(set) var hasFrame = false
    private var failureType: String?

    func recordFrame() -> Bool {
        let isFirst = !hasFrame
        hasFrame = true
        return isFirst
    }

    func record(_ events: [BusyBarInputEvent]) {
        for event in events {
            switch event {
            case .button(let button, action: .press):
                buttons.insert(String(describing: button))
            case .button:
                break
            case .selector(let position):
                selectors.insert(String(describing: position))
            case .encoder(let delta) where delta > 0:
                sawClockwise = true
            case .encoder(let delta) where delta < 0:
                sawCounterclockwise = true
            case .encoder:
                break
            }
        }
    }

    func recordFailure(_ type: String) {
        failureType = type
    }

    func resetInputs() {
        buttons = []
        selectors = []
        sawClockwise = false
        sawCounterclockwise = false
    }

    func result() -> HardwareInputResult {
        HardwareInputResult(
            automaticIsComplete: automaticIsComplete,
            physicalIsComplete: physicalIsComplete,
            summary: [
                "buttons=\(buttons.sorted().joined(separator: ","))",
                "selectors=\(selectors.sorted().joined(separator: ","))",
                "clockwise=\(sawClockwise)",
                "counterclockwise=\(sawCounterclockwise)",
            ].joined(separator: "; "),
            failureType: failureType
        )
    }

    private var automaticIsComplete: Bool {
        buttons == ["back", "ok", "start"]
            && sawClockwise
            && sawCounterclockwise
    }

    private var physicalIsComplete: Bool {
        automaticIsComplete && selectors == ["busy", "custom", "off"]
    }
}

private struct HardwareInputResult: Sendable {
    let automaticIsComplete: Bool
    let physicalIsComplete: Bool
    let summary: String
    let failureType: String?
}
