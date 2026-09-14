public struct BusyBarAPICompatibility: Equatable, Sendable {
    public static let clientVersion = "27.5.0"

    public let clientVersion: String
    public let deviceVersion: String

    public init(
        clientVersion: String = Self.clientVersion,
        deviceVersion: String
    ) throws {
        guard let client = SemanticVersion(clientVersion) else {
            throw BusyBarHTTPError.invalidAPIVersion(clientVersion)
        }
        guard let device = SemanticVersion(deviceVersion) else {
            throw BusyBarHTTPError.invalidAPIVersion(deviceVersion)
        }

        guard client.major == device.major, client.minor <= device.minor else {
            throw BusyBarHTTPError.incompatibleAPIVersion(
                client: clientVersion,
                device: deviceVersion
            )
        }

        self.clientVersion = clientVersion
        self.deviceVersion = deviceVersion
    }
}

private struct SemanticVersion {
    let major: Int
    let minor: Int

    init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return nil
        }

        let minorDigits = components[1].prefix(while: { $0.isNumber })
        guard !minorDigits.isEmpty,
              let major = Int(components[0]),
              let minor = Int(minorDigits),
              major >= 0,
              minor >= 0
        else {
            return nil
        }

        self.major = major
        self.minor = minor
    }
}
