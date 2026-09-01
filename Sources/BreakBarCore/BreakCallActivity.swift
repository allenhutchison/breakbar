import Foundation

public enum BreakCallConfidence: String, Codable, Equatable, Sendable {
    case dedicatedApplication
    case calendarCorrelatedBrowser
    case userApprovedBrowser
}

public struct BreakCallSignal: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let confidence: BreakCallConfidence

    public init(bundleIdentifier: String, confidence: BreakCallConfidence) {
        self.bundleIdentifier = bundleIdentifier
        self.confidence = confidence
    }
}

public enum BreakCallApplicationClassifier {
    public static func signal(for bundleIdentifier: String) -> BreakCallSignal? {
        let normalized = bundleIdentifier.lowercased()
        let dedicatedApplications: [(prefix: String, canonical: String)] = [
            ("us.zoom.xos", "us.zoom.xos"),
            ("com.microsoft.teams2", "com.microsoft.teams2"),
            ("com.microsoft.teams", "com.microsoft.teams"),
            ("com.apple.facetime", "com.apple.FaceTime"),
            ("com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap"),
            ("com.cisco.webexmeetingsapp", "com.cisco.webexmeetingsapp"),
            ("cisco-systems.spark", "Cisco-Systems.Spark"),
        ]
        if let application = dedicatedApplications.first(where: {
            normalized == $0.prefix || normalized.hasPrefix("\($0.prefix).")
        }) {
            return BreakCallSignal(
                bundleIdentifier: application.canonical,
                confidence: .dedicatedApplication
            )
        }

        let browsers: [(prefix: String, canonical: String)] = [
            ("com.apple.safari", "com.apple.Safari"),
            ("com.google.chrome", "com.google.Chrome"),
            ("com.microsoft.edgemac", "com.microsoft.edgemac"),
            ("company.thebrowser.browser", "company.thebrowser.Browser"),
            ("org.mozilla.firefox", "org.mozilla.firefox"),
            ("com.brave.browser", "com.brave.Browser"),
        ]
        guard let browser = browsers.first(where: {
            normalized == $0.prefix || normalized.hasPrefix("\($0.prefix).")
        }) else {
            return nil
        }
        return BreakCallSignal(
            bundleIdentifier: browser.canonical,
            confidence: .calendarCorrelatedBrowser
        )
    }
}

public enum BreakCallCorrelation {
    public static func acceptedSignal(
        rawSignal: BreakCallSignal?,
        currentAcceptedSignal: BreakCallSignal?,
        constraints: [BreakCalendarConstraint],
        at date: Date,
        allowUncorrelatedBrowser: Bool = false,
        tolerance: TimeInterval = 5 * 60
    ) -> BreakCallSignal? {
        guard let rawSignal else { return nil }
        if rawSignal.confidence == .dedicatedApplication {
            return rawSignal
        }
        if allowUncorrelatedBrowser {
            return BreakCallSignal(
                bundleIdentifier: rawSignal.bundleIdentifier,
                confidence: .userApprovedBrowser
            )
        }
        if currentAcceptedSignal?.bundleIdentifier == rawSignal.bundleIdentifier {
            return currentAcceptedSignal
        }

        let isNearCalendarMeeting = constraints.contains { meeting in
            date >= meeting.startAt.addingTimeInterval(-tolerance)
                && date < meeting.endAt.addingTimeInterval(tolerance)
        }
        return isNearCalendarMeeting ? rawSignal : nil
    }
}

public struct BreakCallActivityDebouncer: Equatable, Sendable {
    public private(set) var stableSignal: BreakCallSignal?

    private var candidateSignal: BreakCallSignal?
    private var candidateStartedAt: Date?
    private let startDelay: TimeInterval
    private let stopDelay: TimeInterval

    public init(
        stableSignal: BreakCallSignal? = nil,
        startDelay: TimeInterval = 2,
        stopDelay: TimeInterval = 5
    ) {
        precondition(startDelay >= 0)
        precondition(stopDelay >= 0)
        self.stableSignal = stableSignal
        self.startDelay = startDelay
        self.stopDelay = stopDelay
    }

    @discardableResult
    public mutating func update(
        rawSignal: BreakCallSignal?,
        at date: Date
    ) -> BreakCallSignal? {
        if rawSignal == stableSignal {
            candidateSignal = nil
            candidateStartedAt = nil
            return stableSignal
        }

        if rawSignal != candidateSignal || candidateStartedAt == nil {
            candidateSignal = rawSignal
            candidateStartedAt = date
        }

        let delay = rawSignal == nil ? stopDelay : startDelay
        guard let candidateStartedAt,
              date.timeIntervalSince(candidateStartedAt) >= delay
        else {
            return stableSignal
        }

        stableSignal = rawSignal
        candidateSignal = nil
        self.candidateStartedAt = nil
        return stableSignal
    }
}
