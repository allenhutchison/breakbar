import Foundation

public protocol BusyBarHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public protocol BusyBarDeviceClient: Sendable {
    func verifyCompatibility() async throws -> BusyBarAPICompatibility
    func drawFrontText(
        _ text: String,
        color: String,
        timeoutSeconds: Int
    ) async throws
    func clearOwnedDisplay() async throws
}

public struct URLSessionBusyBarHTTPTransport: BusyBarHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BusyBarHTTPError.nonHTTPResponse
        }
        return (data, response)
    }
}

public struct BusyBarAPIVersion: Decodable, Equatable, Sendable {
    public let semanticVersion: String

    private enum CodingKeys: String, CodingKey {
        case semanticVersion = "api_semver"
    }
}

public enum BusyBarHTTPError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidText
    case invalidTimeout
    case invalidAPIVersion(String)
    case incompatibleAPIVersion(client: String, device: String)
    case nonHTTPResponse
    case authenticationRequired
    case displayConflict
    case unexpectedStatus(Int)
}

public struct BusyBarHTTPClient: BusyBarDeviceClient, Sendable {
    public static let applicationName = "breakbar"

    private let baseURL: URL
    private let apiToken: String?
    private let transport: any BusyBarHTTPTransport

    public init(
        baseURL: URL,
        apiToken: String? = nil,
        transport: any BusyBarHTTPTransport = URLSessionBusyBarHTTPTransport()
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil,
              baseURL.path.isEmpty || baseURL.path == "/"
        else {
            throw BusyBarHTTPError.invalidBaseURL
        }

        self.baseURL = baseURL
        self.apiToken = apiToken
        self.transport = transport
    }

    public func apiVersion() async throws -> BusyBarAPIVersion {
        let request = makeRequest(path: "api/version", method: "GET")
        let data = try await perform(request)
        return try JSONDecoder().decode(BusyBarAPIVersion.self, from: data)
    }

    @discardableResult
    public func verifyCompatibility() async throws -> BusyBarAPICompatibility {
        let version = try await apiVersion()
        return try BusyBarAPICompatibility(deviceVersion: version.semanticVersion)
    }

    /// Draws centered text on the 72 x 16 front display. A non-zero timeout is
    /// required so a disconnected Mac cannot leave stale BreakBar state behind.
    public func drawFrontText(
        _ text: String,
        color: String = "#FFFFFFFF",
        timeoutSeconds: Int
    ) async throws {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ 0x20 ... 0x7E ~= $0.value })
        else {
            throw BusyBarHTTPError.invalidText
        }
        guard timeoutSeconds > 0 else {
            throw BusyBarHTTPError.invalidTimeout
        }

        var request = makeRequest(path: "api/display/draw", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DrawRequest(
                applicationName: Self.applicationName,
                priority: 50,
                elements: [
                    TextElement(
                        id: "status",
                        timeout: timeoutSeconds,
                        text: text,
                        font: "normal",
                        color: color,
                        x: 36,
                        y: 8,
                        display: "front",
                        align: "center"
                    )
                ]
            )
        )
        _ = try await perform(request)
    }

    public func clearOwnedDisplay() async throws {
        var components = URLComponents(
            url: endpoint(path: "api/display/draw"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "application_name", value: Self.applicationName)
        ]
        guard let url = components?.url else {
            throw BusyBarHTTPError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        configure(&request)
        _ = try await perform(request)
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: endpoint(path: path))
        request.httpMethod = method
        configure(&request)
        return request
    }

    private func endpoint(path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func configure(_ request: inout URLRequest) {
        request.timeoutInterval = 5
        request.setValue(
            BusyBarAPICompatibility.clientVersion,
            forHTTPHeaderField: "X-Busy-Api-Version"
        )
        if let apiToken {
            request.setValue(apiToken, forHTTPHeaderField: "X-API-Token")
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200 ..< 300:
            return data
        case 401, 403:
            throw BusyBarHTTPError.authenticationRequired
        case 409:
            throw BusyBarHTTPError.displayConflict
        default:
            throw BusyBarHTTPError.unexpectedStatus(response.statusCode)
        }
    }
}

private struct DrawRequest: Encodable {
    let applicationName: String
    let priority: Int
    let elements: [TextElement]

    private enum CodingKeys: String, CodingKey {
        case applicationName = "application_name"
        case priority
        case elements
    }
}

private struct TextElement: Encodable {
    let id: String
    let type = "text"
    let timeout: Int
    let text: String
    let font: String
    let color: String
    let x: Int
    let y: Int
    let display: String
    let align: String
}
