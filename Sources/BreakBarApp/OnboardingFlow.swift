import Foundation

enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome
    case notifications
    case calendar
    case obsidian
    case options
    case ready
}

struct OnboardingProgress: Equatable, Sendable {
    private(set) var step: OnboardingStep = .welcome

    var position: Int {
        step.rawValue + 1
    }

    var canMoveBack: Bool {
        step != .welcome
    }

    var isFinalStep: Bool {
        step == .ready
    }

    mutating func moveForward() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    mutating func moveBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
}

enum OnboardingPreferences {
    static let currentVersion = 1
    static let completedVersionKey = "onboarding.completedVersion"

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completedVersionKey) < currentVersion
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: completedVersionKey)
    }
}
