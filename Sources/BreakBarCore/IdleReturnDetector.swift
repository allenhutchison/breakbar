import Foundation

public struct IdleReturnDetector: Sendable {
    private var observedTrackedIdle = false

    public init() {}

    public mutating func reset() {
        observedTrackedIdle = false
    }

    public mutating func update(
        isTracking: Bool,
        canPrompt: Bool = true,
        idleDuration: TimeInterval,
        idleThreshold: TimeInterval,
        returnThreshold: TimeInterval = 2
    ) -> Bool {
        guard isTracking else {
            observedTrackedIdle = false
            return false
        }
        guard idleDuration.isFinite, idleDuration >= 0 else { return false }

        if idleDuration >= idleThreshold {
            observedTrackedIdle = true
            return false
        }

        guard observedTrackedIdle,
              canPrompt,
              idleDuration < returnThreshold
        else {
            return false
        }
        observedTrackedIdle = false
        return true
    }
}
