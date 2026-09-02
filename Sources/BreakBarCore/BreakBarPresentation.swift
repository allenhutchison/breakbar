import Foundation

public struct BreakBarTimerPresentation: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case countDown
        case countUp
    }

    public let direction: Direction
    public let interval: TimeInterval

    public init(direction: Direction, interval: TimeInterval) {
        self.direction = direction
        self.interval = max(0, interval)
    }

    public var text: String {
        let clock = BreakBarPresentation.clock(interval)
        return direction == .countUp ? "+\(clock)" : clock
    }
}

public struct BreakBarPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral
        case focus
        case meeting
        case warning
        case required
        case breakTime
        case lunch
    }

    public var statusLabel: String
    public var timer: BreakBarTimerPresentation?
    public var title: String
    public var detail: String
    public var progress: Double
    public var tone: Tone
    public var primaryActionTitle: String?

    public var shortLabel: String {
        timer?.text ?? statusLabel
    }

    public init(state: BreakBarState, policy: BreakPolicy, now: Date) {
        switch state.phase {
        case .clockedOut:
            statusLabel = "BreakBar"
            timer = nil
            title = "Ready when you are"
            detail = "Clock in to begin a \(Self.spoken(policy.focusDuration)) focus cycle."
            progress = 0
            tone = .neutral
            primaryActionTitle = "Clock in"

        case .focusing:
            if let manualMeetingStartedAt = state.manualMeetingStartedAt {
                statusLabel = ""
                timer = BreakBarTimerPresentation(
                    direction: .countUp,
                    interval: now.timeIntervalSince(manualMeetingStartedAt)
                )
                title = "In a meeting"
                detail = "Break enforcement is paused until you end this meeting."
                progress = 1
                tone = .meeting
                primaryActionTitle = "End meeting"
                return
            }

            if let liveCallStartedAt = state.liveCallStartedAt {
                let timer: BreakBarTimerPresentation
                let title: String
                if let meetingStartsAt = state.calendarMeetingStartsAt,
                   let meetingEndsAt = state.calendarMeetingEndsAt,
                   now >= meetingStartsAt
                {
                    if now < meetingEndsAt {
                        timer = BreakBarTimerPresentation(
                            direction: .countDown,
                            interval: meetingEndsAt.timeIntervalSince(now)
                        )
                        title = "In a meeting"
                    } else {
                        timer = BreakBarTimerPresentation(
                            direction: .countUp,
                            interval: now.timeIntervalSince(meetingEndsAt)
                        )
                        title = "Meeting overrun"
                    }
                } else {
                    timer = BreakBarTimerPresentation(
                        direction: .countUp,
                        interval: now.timeIntervalSince(liveCallStartedAt)
                    )
                    title = "In a call"
                }
                statusLabel = ""
                self.timer = timer
                self.title = title
                detail = "Break enforcement is paused while microphone call activity continues."
                progress = 1
                tone = .meeting
                primaryActionTitle = nil
                return
            }

            if let meetingStartsAt = state.calendarMeetingStartsAt,
               let meetingEndsAt = state.calendarMeetingEndsAt,
               meetingStartsAt <= now,
               now < meetingEndsAt
            {
                let remaining = meetingEndsAt.timeIntervalSince(now)
                let duration = max(1, meetingEndsAt.timeIntervalSince(meetingStartsAt))
                statusLabel = ""
                timer = BreakBarTimerPresentation(direction: .countDown, interval: remaining)
                title = "In a meeting"
                detail = "Break enforcement is paused until this scheduled meeting ends."
                progress = min(1, max(0, now.timeIntervalSince(meetingStartsAt) / duration))
                tone = .meeting
                primaryActionTitle = nil
                return
            }

            let remaining = max(0, (state.focusDueAt ?? now).timeIntervalSince(now))
            if state.enforcement == .required {
                statusLabel = "BREAK"
                timer = nil
            } else {
                statusLabel = ""
                timer = BreakBarTimerPresentation(direction: .countDown, interval: remaining)
            }
            title = state.enforcement == .required
                ? "Time to get up"
                : state.enforcement == .warning ? "Find a stopping point" : "Focus"
            if state.enforcement == .required {
                detail = "Start the break on this Mac or with a connected accessory."
            } else if state.enforcement == .warning {
                detail = state.breakPlanReason == .postMeetingWarning
                    ? "Your meeting ended. Break begins in \(Self.spoken(remaining))."
                    : "Your break begins in \(Self.spoken(remaining))."
            } else {
                switch state.breakPlanReason {
                case .pulledBeforeMeeting:
                    detail = "Break moved before your next meeting: \(Self.spoken(remaining)) remaining."
                case .deferredThroughMeeting:
                    detail = "Break follows your meeting with a fresh warning."
                case .postMeetingWarning:
                    detail = "Your meeting ended. Break begins in \(Self.spoken(remaining))."
                case .nominal, nil:
                    detail = "Next break in \(Self.spoken(remaining))."
                }
            }
            progress = min(1, max(0, 1 - remaining / policy.focusDuration))
            tone = state.enforcement == .required ? .required : state.enforcement == .warning ? .warning : .focus
            primaryActionTitle = state.enforcement == .required ? "Start break" : "Take a break now"

        case .onBreak:
            let minimumEnd = state.minimumBreakEndsAt ?? now
            let remaining = max(0, minimumEnd.timeIntervalSince(now))
            let elapsed = max(0, now.timeIntervalSince(minimumEnd))
            let minimumSatisfied = remaining <= 0
            statusLabel = ""
            timer = BreakBarTimerPresentation(
                direction: minimumSatisfied ? .countUp : .countDown,
                interval: minimumSatisfied ? elapsed : remaining
            )
            title = minimumSatisfied ? "Break complete" : "Stay away a little longer"
            detail = minimumSatisfied
                ? "Return when you’re ready; the extra time still counts."
                : "Minimum break remaining: \(Self.spoken(remaining))."
            progress = minimumSatisfied ? 1 : min(1, max(0, 1 - remaining / policy.minimumBreakDuration))
            tone = .breakTime
            primaryActionTitle = minimumSatisfied ? "Return to focus" : nil

        case .onLunch:
            let elapsed = max(0, now.timeIntervalSince(state.phaseStartedAt ?? now))
            statusLabel = ""
            timer = BreakBarTimerPresentation(direction: .countUp, interval: elapsed)
            title = "Lunch"
            detail = "Break enforcement is paused. End lunch to begin a fresh focus cycle."
            progress = 1
            tone = .lunch
            primaryActionTitle = "End lunch"
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
