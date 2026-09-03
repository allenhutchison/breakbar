import Foundation

public struct ClockedOutReturnDetector: Sendable {
    private var observedIdleWhileClockedOut = false

    public init() {}

    public mutating func reset() {
        observedIdleWhileClockedOut = false
    }

    public mutating func update(
        isClockedOut: Bool,
        idleDuration: TimeInterval,
        idleThreshold: TimeInterval,
        returnThreshold: TimeInterval = 2
    ) -> Bool {
        guard isClockedOut else {
            observedIdleWhileClockedOut = false
            return false
        }
        guard idleDuration.isFinite, idleDuration >= 0 else { return false }

        if idleDuration >= idleThreshold {
            observedIdleWhileClockedOut = true
            return false
        }

        guard observedIdleWhileClockedOut, idleDuration < returnThreshold else {
            return false
        }
        observedIdleWhileClockedOut = false
        return true
    }
}
