import CoreGraphics
import Foundation

enum IdleActivityMonitor {
    static var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
    }
}
