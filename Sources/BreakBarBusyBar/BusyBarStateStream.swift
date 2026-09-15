import Foundation

public struct BusyBarStateMessage: Equatable, Sendable {
    public let inputEvents: [BusyBarInputEvent]

    public init(inputEvents: [BusyBarInputEvent]) {
        self.inputEvents = inputEvents
    }
}

public protocol BusyBarStateStreaming: Sendable {
    func messages() -> AsyncThrowingStream<BusyBarStateMessage, Error>
}

public enum BusyBarStateStreamError: Error, Equatable, Sendable {
    case invalidBaseURL
    case connectionClosed(Int)
}

public struct BusyBarStateStream: BusyBarStateStreaming, Sendable {
    let socketURL: URL

    public init(baseURL: URL, apiToken: String? = nil) throws {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           components.host != nil,
           components.path.isEmpty || components.path == "/"
        else {
            throw BusyBarStateStreamError.invalidBaseURL
        }

        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = "/api/status/ws"
        components.query = nil
        components.fragment = nil
        if let apiToken {
            components.queryItems = [
                URLQueryItem(name: "x-api-token", value: apiToken)
            ]
        }
        guard let socketURL = components.url else {
            throw BusyBarStateStreamError.invalidBaseURL
        }
        self.socketURL = socketURL
    }

    public func messages() -> AsyncThrowingStream<BusyBarStateMessage, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let delegate = BusyBarWebSocketDelegate()
            let session = URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
            var request = URLRequest(url: socketURL)
            request.timeoutInterval = 5
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 4 * 1024 * 1024

            let reader = Task {
                defer {
                    socket.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                }

                do {
                    socket.resume()
                    try await delegate.waitUntilOpen()
                    try Task.checkCancellation()
                    try await socket.send(.string(#"{"enable":true}"#))

                    while !Task.isCancelled {
                        switch try await socket.receive() {
                        case .data(let data):
                            continuation.yield(
                                BusyBarStateMessage(
                                    inputEvents: try BusyBarStateDecoder
                                        .decodeInputEvents(from: data)
                                )
                            )
                        case .string:
                            continue
                        @unknown default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                reader.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
        }
    }
}

private final class BusyBarWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private let openEvents: AsyncThrowingStream<Void, Error>
    private let openContinuation: AsyncThrowingStream<Void, Error>.Continuation

    override init() {
        (openEvents, openContinuation) = AsyncThrowingStream.makeStream(of: Void.self)
        super.init()
    }

    func waitUntilOpen() async throws {
        for try await _ in openEvents {
            return
        }
        throw BusyBarStateStreamError.connectionClosed(0)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        openContinuation.yield()
        openContinuation.finish()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        openContinuation.finish(
            throwing: BusyBarStateStreamError.connectionClosed(closeCode.rawValue)
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            openContinuation.finish(throwing: error)
        }
    }
}
