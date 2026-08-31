import Foundation

public struct BreakBarPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral
        case focus
        case warning
        case required
        case breakTime
    }

    public var shortLabel: String
    public var title: String
    public var detail: String
    public var progress: Double
    public var tone: Tone
    public var primaryActionTitle: String?

    public init(state: BreakBarState, policy: BreakPolicy, now: Date) {
        switch state.phase {
        case .clockedOut:
            shortLabel = "BreakBar"
            title = "Ready when you are"
            detail = "Clock in to begin a \(Self.spoken(policy.focusDuration)) focus cycle."
            progress = 0
            tone = .neutral
            primaryActionTitle = "Clock in"

        case .focusing:
            let remaining = max(0, (state.focusDueAt ?? now).timeIntervalSince(now))
            shortLabel = state.enforcement == .required ? "BREAK" : Self.clock(remaining)
            title = state.enforcement == .required
                ? "Time to get up"
                : state.enforcement == .warning ? "Find a stopping point" : "Focus"
            detail = state.enforcement == .required
                ? "Start the break on this Mac or with a connected accessory."
                : state.enforcement == .warning
                    ? "Your break begins in \(Self.spoken(remaining))."
                    : "Next break in \(Self.spoken(remaining))."
            progress = min(1, max(0, 1 - remaining / policy.focusDuration))
            tone = state.enforcement == .required ? .required : state.enforcement == .warning ? .warning : .focus
            primaryActionTitle = state.enforcement == .required ? "Start break" : "Take a break now"

        case .onBreak:
            let minimumEnd = state.minimumBreakEndsAt ?? now
            let remaining = max(0, minimumEnd.timeIntervalSince(now))
            let elapsed = max(0, now.timeIntervalSince(minimumEnd))
            let minimumSatisfied = remaining <= 0
            shortLabel = minimumSatisfied ? "+\(Self.clock(elapsed))" : Self.clock(remaining)
            title = minimumSatisfied ? "Break complete" : "Stay away a little longer"
            detail = minimumSatisfied
                ? "Return when you’re ready; the extra time still counts."
                : "Minimum break remaining: \(Self.spoken(remaining))."
            progress = minimumSatisfied ? 1 : min(1, max(0, 1 - remaining / policy.minimumBreakDuration))
            tone = .breakTime
            primaryActionTitle = minimumSatisfied ? "Return to focus" : nil
        }
    }

    public static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func spoken(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder) seconds" }
        if remainder == 0 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return "\(minutes) min \(remainder) sec"
    }
}
