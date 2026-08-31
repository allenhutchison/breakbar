import Foundation

public struct BreakPolicy: Codable, Equatable, Sendable {
    public var focusDuration: TimeInterval
    public var warningDuration: TimeInterval
    public var minimumBreakDuration: TimeInterval

    public init(
        focusDuration: TimeInterval = 55 * 60,
        warningDuration: TimeInterval = 5 * 60,
        minimumBreakDuration: TimeInterval = 5 * 60
    ) {
        precondition(focusDuration > 0)
        precondition(warningDuration >= 0 && warningDuration <= focusDuration)
        precondition(minimumBreakDuration > 0)
        self.focusDuration = focusDuration
        self.warningDuration = warningDuration
        self.minimumBreakDuration = minimumBreakDuration
    }

    public static let standard = BreakPolicy()
}
