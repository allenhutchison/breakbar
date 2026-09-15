import Foundation

public struct AccessoryCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let display = AccessoryCapabilities(rawValue: 1 << 0)
    public static let input = AccessoryCapabilities(rawValue: 1 << 1)
    public static let feedback = AccessoryCapabilities(rawValue: 1 << 2)
    public static let presence = AccessoryCapabilities(rawValue: 1 << 3)
}

public enum AccessoryEvent: Equatable, Sendable {
    case startBreak(id: UUID, revision: UInt64)
    case returnToFocus(id: UUID, revision: UInt64)
    case presenceChanged(isPresent: Bool, id: UUID)
}

/// A capability-based extension point for optional hardware. The app remains
/// fully functional when no implementations are installed.
public protocol BreakBarAccessory: Sendable {
    var identifier: String { get }
    var capabilities: AccessoryCapabilities { get }

    func connect() async throws
    func disconnect() async
    func render(_ presentation: BreakBarPresentation, revision: UInt64) async throws
    func events() -> AsyncStream<AccessoryEvent>
}
