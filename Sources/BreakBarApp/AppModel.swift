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

    let policy: BreakPolicy
    let isDemoMode: Bool
    let calendarMonitor = CalendarMonitor()
    let callActivityMonitor = CallActivityMonitor()

    private var engine: BreakBarEngine
    private let repository: SessionRepository?
    private let overlayController = OverlayController()
    private let breakReturnPanelController = BreakReturnPanelController()
    private var ticker: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()

    init() {
        isDemoMode = CommandLine.arguments.contains("--demo")
        policy = isDemoMode
            ? BreakPolicy(focusDuration: 60, warningDuration: 15, minimumBreakDuration: 20)
            : .standard

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
        engine = BreakBarEngine(state: restored, policy: policy)
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
            startBreak()
        case .onBreak:
            returnToFocus()
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

    func reconcileAfterLifecycleEvent() {
        let eventDate = Date()
        applyCurrentCalendarConstraints(at: eventDate)
        applyCurrentCallActivity(at: eventDate)
        _ = apply(.reconcile, at: eventDate)
        synchronizeWindows(at: eventDate, bringReturnPanelToFront: true)
    }

    private func tick() {
        let eventDate = Date()
        let displayedText = presentation.shortLabel
        let calendarResult = applyCurrentCalendarConstraints(at: eventDate)
        let callResult = applyCurrentCallActivity(at: eventDate)
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
        if state.phase == .focusing && state.enforcement == .required {
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
