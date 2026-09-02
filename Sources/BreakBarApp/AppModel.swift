import AppKit
import BreakBarCore
import BreakBarPersistence
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: BreakBarState
    @Published private(set) var now: Date
    @Published private(set) var lastMessage: String?
    @Published private(set) var launchAtLoginRequested: Bool
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var acceptedCallSignal: BreakCallSignal?
    @Published private(set) var allowUncorrelatedBrowserCalls: Bool
    @Published private(set) var policy: BreakPolicy

    let isDemoMode: Bool
    let calendarMonitor = CalendarMonitor()
    let callActivityMonitor = CallActivityMonitor()

    private var engine: BreakBarEngine
    private let repository: SessionRepository?
    private let overlayController = OverlayController()
    private let breakReturnPanelController = BreakReturnPanelController()
    private let awayReturnPanelController = AwayReturnPanelController()
    private var ticker: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()

    init() {
        isDemoMode = CommandLine.arguments.contains("--demo")
        let initialPolicy = isDemoMode
            ? Self.demoPolicy
            : Self.loadPolicyPreferences()
        policy = initialPolicy

        var restored = BreakBarState()
        var loadedRepository: SessionRepository?
        var startupMessage: String?
        do {
            let databaseURL = try Self.databaseURL(isDemoMode: isDemoMode)
            let repository = try SessionRepository(url: databaseURL)
            try repository.bootstrapIfNeeded(
                state: isDemoMode
                    ? BreakBarState()
                    : LegacyStatePersistence.load() ?? BreakBarState()
            )
            restored = try repository.loadState() ?? BreakBarState()
            loadedRepository = repository
        } catch {
            startupMessage = "BreakBar could not open its history database: \(error.localizedDescription)"
        }

        repository = loadedRepository
        engine = BreakBarEngine(state: restored, policy: initialPolicy)
        state = engine.state
        now = Date()
        lastMessage = startupMessage
        launchAtLoginRequested = false
        launchAtLoginMessage = nil
        acceptedCallSignal = nil
        allowUncorrelatedBrowserCalls = UserDefaults.standard.bool(
            forKey: Self.allowUncorrelatedBrowserCallsKey
        )
        refreshLaunchAtLoginStatus()

        calendarMonitor.$schedulingConstraints
            .removeDuplicates()
            .sink { [weak self] constraints in
                self?.calendarConstraintsChanged(constraints)
            }
            .store(in: &observations)

        callActivityMonitor.$signal
            .removeDuplicates()
            .sink { [weak self] signal in
                self?.callActivityChanged(signal)
            }
            .store(in: &observations)

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let currentTime = Date().timeIntervalSince1970
                let nextSecond = floor(currentTime) + 1
                try? await Task.sleep(for: .seconds(nextSecond - currentTime))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }

        Task { [weak self] in
            self?.tick()
        }
    }

    deinit {
        ticker?.cancel()
    }

    var presentation: BreakBarPresentation {
        BreakBarPresentation(state: state, policy: policy, now: now)
    }

    var menuBarSymbol: String {
        switch presentation.tone {
        case .neutral: "figure.stand"
        case .focus: "timer"
        case .meeting: "video.fill"
        case .warning: "exclamationmark.circle.fill"
        case .required: "figure.walk.motion"
        case .breakTime: "cup.and.heat.waves.fill"
        case .lunch: "fork.knife"
        case .away: "figure.walk"
        case .travel: "car.fill"
        }
    }

    var canReturnEarly: Bool {
        guard state.phase == .onBreak else { return false }
        return (state.minimumBreakEndsAt ?? now) <= now
    }

    func performPrimaryAction() {
        switch state.phase {
        case .clockedOut:
            clockIn()
        case .focusing:
            if state.manualMeetingStartedAt != nil {
                endManualMeeting()
            } else {
                startBreak()
            }
        case .onBreak:
            returnToFocus()
        case .onLunch:
            endLunch()
        case .awayUnclassified:
            break
        case .traveling, .offsiteMeeting:
            returnHome()
        }
    }

    func clockIn() {
        let eventDate = Date()
        if apply(.clockIn, at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
    }

    func clockOut() {
        apply(.clockOut)
    }

    func emergencyClockOut() {
        apply(.emergencyClockOut)
    }

    func startBreak() {
        beginBreak(with: .startBreak)
    }

    func startLunch() {
        apply(.startLunch)
    }

    func endLunch() {
        let eventDate = Date()
        if apply(.endLunch, at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
    }

    func startManualMeeting() {
        apply(.startManualMeeting)
    }

    func endManualMeeting() {
        let eventDate = Date()
        if apply(.endManualMeeting, at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
            _ = apply(.tick, at: eventDate)
        }
    }

    func classifyAway(as classification: AwayClassification) {
        let eventDate = Date()
        if apply(.classifyAway(classification), at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
            _ = apply(.tick, at: eventDate)
        }
    }

    func emergencyStartBreak() {
        beginBreak(with: .emergencyStartBreak)
    }

    func returnToFocus() {
        let eventDate = Date()
        let result = apply(.returnToFocus, at: eventDate)
        if result == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
        if case let .rejected(remaining) = result {
            lastMessage = "Stay away for another \(BreakBarPresentation.clock(remaining))."
        }
    }

    func acknowledgeTravel() {
        apply(.acknowledgeTravel)
    }

    func returnHome() {
        let eventDate = Date()
        if apply(.returnHome, at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
    }

    private func beginBreak(with command: BreakCommand) {
        guard apply(command) == .changed else { return }
        if let mediaMessage = MediaPlaybackController.pauseRunningPlayers() {
            lastMessage = mediaMessage
        }
        SystemActions.startScreensaver()
    }

    func clearMessage() {
        lastMessage = nil
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func setLaunchAtLogin(_ requested: Bool) {
        let service = SMAppService.mainApp
        do {
            if requested {
                try service.register()
            } else {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "BreakBar could not update Login Items: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setFocusDuration(_ duration: TimeInterval) {
        let validatedDuration = min(99 * 60, max(15 * 60, duration))
        replacePolicy(
            BreakPolicy(
                focusDuration: validatedDuration,
                warningDuration: min(policy.warningDuration, validatedDuration),
                minimumBreakDuration: policy.minimumBreakDuration,
                maximumSeatedDuration: max(
                    BreakPolicy.standard.maximumSeatedDuration,
                    validatedDuration
                ),
                idleThreshold: policy.idleThreshold
            )
        )
    }

    func setWarningDuration(_ duration: TimeInterval) {
        let validatedDuration = min(
            min(15 * 60, policy.focusDuration),
            max(60, duration)
        )
        replacePolicy(
            BreakPolicy(
                focusDuration: policy.focusDuration,
                warningDuration: validatedDuration,
                minimumBreakDuration: policy.minimumBreakDuration,
                maximumSeatedDuration: policy.maximumSeatedDuration,
                idleThreshold: policy.idleThreshold
            )
        )
    }

    func setMinimumBreakDuration(_ duration: TimeInterval) {
        let validatedDuration = min(30 * 60, max(60, duration))
        replacePolicy(
            BreakPolicy(
                focusDuration: policy.focusDuration,
                warningDuration: policy.warningDuration,
                minimumBreakDuration: validatedDuration,
                maximumSeatedDuration: policy.maximumSeatedDuration,
                idleThreshold: policy.idleThreshold
            )
        )
    }

    func setIdleThreshold(_ duration: TimeInterval) {
        let validatedDuration = min(60 * 60, max(60, duration))
        replacePolicy(
            BreakPolicy(
                focusDuration: policy.focusDuration,
                warningDuration: policy.warningDuration,
                minimumBreakDuration: policy.minimumBreakDuration,
                maximumSeatedDuration: policy.maximumSeatedDuration,
                idleThreshold: validatedDuration
            )
        )
    }

    func resetTimingPreferences() {
        replacePolicy(isDemoMode ? Self.demoPolicy : .standard)
    }

    func reconcileAfterLifecycleEvent() {
        let eventDate = Date()
        applyCurrentCalendarConstraints(at: eventDate)
        applyCurrentCallActivity(at: eventDate)
        _ = updateIdleState(at: eventDate)
        _ = apply(.reconcile, at: eventDate)
        synchronizeWindows(at: eventDate, bringReturnPanelToFront: true)
    }

    private func tick() {
        let eventDate = Date()
        let displayedText = presentation.shortLabel
        let calendarResult = applyCurrentCalendarConstraints(at: eventDate)
        let callResult = applyCurrentCallActivity(at: eventDate)
        let idleResult = updateIdleState(at: eventDate)
        let timerResult = apply(.tick, at: eventDate, publishTime: false)
        let nextText = BreakBarPresentation(
            state: state,
            policy: policy,
            now: eventDate
        ).shortLabel

        // A timer wake-up is not itself a UI change. Publish only when the
        // formatted second or state actually changed.
        if calendarResult == .changed
            || callResult == .changed
            || idleResult == .changed
            || timerResult == .changed
            || nextText != displayedText
        {
            now = eventDate
        }
    }

    private func calendarConstraintsChanged(_ constraints: [BreakCalendarConstraint]) {
        let eventDate = Date()
        _ = apply(.updateCalendarConstraints(constraints), at: eventDate)
        _ = applyCurrentCallActivity(at: eventDate)
        _ = apply(.tick, at: eventDate)
    }

    private func callActivityChanged(_ signal: BreakCallSignal?) {
        let eventDate = Date()
        _ = applyCurrentCallActivity(rawSignal: signal, at: eventDate)
        _ = applyCurrentCalendarConstraints(at: eventDate)
        _ = apply(.tick, at: eventDate)
    }

    @discardableResult
    private func updateIdleState(at date: Date) -> BreakCommandResult {
        let idleDuration = IdleActivityMonitor.secondsSinceLastInput
        guard idleDuration.isFinite, idleDuration >= 0 else { return .unchanged }

        if state.phase == .focusing, idleDuration >= policy.idleThreshold {
            return apply(
                .idleThresholdReached(
                    idleStartedAt: date.addingTimeInterval(-idleDuration)
                ),
                at: date,
                publishTime: false
            )
        }

        if state.phase == .awayUnclassified,
           state.awayReturnDetectedAt == nil,
           idleDuration < 2
        {
            return apply(.userActivityResumed, at: date, publishTime: false)
        }

        return .unchanged
    }

    @discardableResult
    private func applyCurrentCalendarConstraints(at date: Date) -> BreakCommandResult {
        apply(
            .updateCalendarConstraints(calendarMonitor.schedulingConstraints),
            at: date,
            publishTime: false
        )
    }

    @discardableResult
    private func applyCurrentCallActivity(at date: Date) -> BreakCommandResult {
        applyCurrentCallActivity(rawSignal: callActivityMonitor.signal, at: date)
    }

    @discardableResult
    private func applyCurrentCallActivity(
        rawSignal: BreakCallSignal?,
        at date: Date
    ) -> BreakCommandResult {
        let acceptedSignal = BreakCallCorrelation.acceptedSignal(
            rawSignal: rawSignal,
            currentAcceptedSignal: acceptedCallSignal,
            constraints: calendarMonitor.schedulingConstraints,
            at: date,
            allowUncorrelatedBrowser: allowUncorrelatedBrowserCalls
        )
        if acceptedCallSignal != acceptedSignal {
            acceptedCallSignal = acceptedSignal
        }
        return apply(
            .updateCallActivity(acceptedSignal),
            at: date,
            publishTime: false
        )
    }

    var activeCallApplicationName: String? {
        guard let bundleIdentifier = acceptedCallSignal?.bundleIdentifier else { return nil }
        return Self.callApplicationNames[bundleIdentifier] ?? bundleIdentifier
    }

    func setAllowUncorrelatedBrowserCalls(_ allowed: Bool) {
        allowUncorrelatedBrowserCalls = allowed
        UserDefaults.standard.set(allowed, forKey: Self.allowUncorrelatedBrowserCallsKey)
        if !allowed, acceptedCallSignal?.confidence == .userApprovedBrowser {
            acceptedCallSignal = nil
        }
        callActivityChanged(callActivityMonitor.signal)
    }

    private static let allowUncorrelatedBrowserCallsKey =
        "call.allowUncorrelatedBrowserMicrophone"

    private static let focusDurationKey = "policy.focusDuration"
    private static let warningDurationKey = "policy.warningDuration"
    private static let minimumBreakDurationKey = "policy.minimumBreakDuration"
    private static let idleThresholdKey = "policy.idleThreshold"

    private static let demoPolicy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20,
        idleThreshold: 10
    )

    private static let callApplicationNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
    ]

    private func replacePolicy(_ nextPolicy: BreakPolicy) {
        guard nextPolicy != policy else { return }
        policy = nextPolicy
        engine.policy = nextPolicy
        if !isDemoMode {
            Self.savePolicyPreferences(nextPolicy)
        }

        let eventDate = Date()
        if state.phase == .focusing {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
            _ = apply(.tick, at: eventDate)
        } else {
            now = eventDate
            synchronizeWindows(at: eventDate)
        }
    }

    private static func loadPolicyPreferences() -> BreakPolicy {
        let defaults = UserDefaults.standard
        let standard = BreakPolicy.standard
        let focusDuration = storedDuration(
            forKey: focusDurationKey,
            fallback: standard.focusDuration,
            range: 15 * 60 ... 99 * 60,
            defaults: defaults
        )
        let warningDuration = storedDuration(
            forKey: warningDurationKey,
            fallback: standard.warningDuration,
            range: 60 ... min(15 * 60, focusDuration),
            defaults: defaults
        )
        let minimumBreakDuration = storedDuration(
            forKey: minimumBreakDurationKey,
            fallback: standard.minimumBreakDuration,
            range: 60 ... 30 * 60,
            defaults: defaults
        )
        let idleThreshold = storedDuration(
            forKey: idleThresholdKey,
            fallback: standard.idleThreshold,
            range: 60 ... 60 * 60,
            defaults: defaults
        )
        return BreakPolicy(
            focusDuration: focusDuration,
            warningDuration: warningDuration,
            minimumBreakDuration: minimumBreakDuration,
            maximumSeatedDuration: max(standard.maximumSeatedDuration, focusDuration),
            idleThreshold: idleThreshold
        )
    }

    private static func storedDuration(
        forKey key: String,
        fallback: TimeInterval,
        range: ClosedRange<TimeInterval>,
        defaults: UserDefaults
    ) -> TimeInterval {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, defaults.double(forKey: key)))
    }

    private static func savePolicyPreferences(_ policy: BreakPolicy) {
        let defaults = UserDefaults.standard
        defaults.set(policy.focusDuration, forKey: focusDurationKey)
        defaults.set(policy.warningDuration, forKey: warningDurationKey)
        defaults.set(policy.minimumBreakDuration, forKey: minimumBreakDurationKey)
        defaults.set(policy.idleThreshold, forKey: idleThresholdKey)
    }

    @discardableResult
    private func apply(
        _ command: BreakCommand,
        at date: Date? = nil,
        publishTime: Bool = true
    ) -> BreakCommandResult {
        let eventDate = date ?? Date()
        let previousState = engine.state
        var candidate = engine
        let result = candidate.handle(command, at: eventDate)
        if publishTime {
            now = eventDate
        }

        if result == .changed {
            guard let repository else {
                lastMessage = "The history database is unavailable, so the timer did not change."
                synchronizeWindows(at: eventDate)
                return .unchanged
            }
            do {
                try repository.commitTransition(
                    from: previousState,
                    to: candidate.state,
                    at: eventDate
                )
            } catch {
                lastMessage = "The timer did not change because it could not be saved: \(error.localizedDescription)"
                synchronizeWindows(at: eventDate)
                return .unchanged
            }
            engine = candidate
            state = candidate.state
            lastMessage = nil
        }
        if previousState.enforcement != .warning && state.enforcement == .warning {
            WarningNotifier.deliver(
                remaining: max(0, (state.focusDueAt ?? eventDate).timeIntervalSince(eventDate)),
                revision: state.revision
            )
        }
        if previousState.enforcement != .travelWarning && state.enforcement == .travelWarning {
            let departureAt = state.travelChain?.map(\.startAt).min() ?? eventDate
            WarningNotifier.deliverTravel(
                remaining: max(0, departureAt.timeIntervalSince(eventDate)),
                revision: state.revision
            )
        }
        synchronizeWindows(at: eventDate)
        return result
    }

    private static func databaseURL(isDemoMode: Bool) throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return base.appendingPathComponent("BreakBar", isDirectory: true)
            .appendingPathComponent(isDemoMode ? "breakbar-demo.sqlite" : "breakbar.sqlite")
    }

    private func synchronizeWindows(
        at date: Date,
        bringReturnPanelToFront: Bool = false
    ) {
        if state.phase == .traveling && state.enforcement == .travelRequired {
            overlayController.showTravel(
                acknowledge: { [weak self] in self?.acknowledgeTravel() },
                clockOut: { [weak self] in self?.clockOut() }
            )
        } else if state.phase == .focusing && state.enforcement == .required {
            overlayController.show(
                startBreak: { [weak self] in self?.startBreak() },
                clockOut: { [weak self] in self?.clockOut() },
                emergencyStartBreak: { [weak self] in self?.emergencyStartBreak() },
                emergencyClockOut: { [weak self] in self?.emergencyClockOut() }
            )
        } else {
            overlayController.hide()
        }

        if state.phase == .onBreak {
            breakReturnPanelController.show(
                presentation: BreakBarPresentation(state: state, policy: policy, now: date),
                canReturn: (state.minimumBreakEndsAt ?? date) <= date,
                bringToFront: bringReturnPanelToFront,
                returnToFocus: { [weak self] in self?.returnToFocus() },
                clockOut: { [weak self] in self?.clockOut() }
            )
        } else {
            breakReturnPanelController.hide()
        }

        if state.phase == .awayUnclassified,
           state.awayReturnDetectedAt != nil
        {
            awayReturnPanelController.show(
                presentation: BreakBarPresentation(state: state, policy: policy, now: date),
                classify: { [weak self] classification in
                    self?.classifyAway(as: classification)
                },
                clockOut: { [weak self] in self?.clockOut() }
            )
        } else {
            awayReturnPanelController.hide()
        }
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginRequested = true
            launchAtLoginMessage = nil
        case .requiresApproval:
            launchAtLoginRequested = true
            launchAtLoginMessage = "Approval is required in System Settings → Login Items."
        case .notRegistered, .notFound:
            launchAtLoginRequested = false
            launchAtLoginMessage = nil
        @unknown default:
            launchAtLoginRequested = false
            launchAtLoginMessage = "The launch-at-login status is unavailable."
        }
    }
}
