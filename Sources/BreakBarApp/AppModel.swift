import AppKit
import BreakBarBusyBar
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
    @Published private(set) var busyBarEnabled: Bool
    @Published private(set) var busyBarAddress: String
    @Published private(set) var busyBarConnectionState: BusyBarConnectionState
    @Published private(set) var notificationAccessState: NotificationAccessState

    let isDemoMode: Bool
    let isUITestMode: Bool
    let calendarMonitor: CalendarMonitor
    let callActivityMonitor: CallActivityMonitor

    private var engine: BreakBarEngine
    private let repository: SessionRepository?
    private let overlayController = OverlayController()
    private let diagnosticsWindowController = DiagnosticsWindowController()
    private let breakReturnPanelController = BreakReturnPanelController()
    private var ticker: Task<Void, Never>?
    private var busyBarAccessory: BusyBarAccessory?
    private var busyBarConnectionTask: Task<Void, Never>?
    private var busyBarEventsTask: Task<Void, Never>?
    private var busyBarCleanupTask: Task<Void, Never>?
    private var busyBarGeneration = UUID()
    private var busyBarRenderRequest = UUID()
    private var busyBarDeviceAPIVersion: String?
    private var busyBarLastSuccessfulWriteAt: Date?
    private var busyBarLastInputAt: Date?
    private var observations = Set<AnyCancellable>()

    init(configuration: AppLaunchConfiguration = .current) {
        isDemoMode = configuration.isDemoMode
        isUITestMode = configuration.isUITestMode
        calendarMonitor = CalendarMonitor(monitoringEnabled: configuration.allowsLiveIntegrations)
        callActivityMonitor = CallActivityMonitor(pollingEnabled: configuration.allowsLiveIntegrations)
        let initialPolicy = isDemoMode
            ? Self.demoPolicy
            : Self.loadPolicyPreferences()
        policy = initialPolicy

        let initialNow = configuration.referenceDate ?? Date()

        var restored = BreakBarState()
        var loadedRepository: SessionRepository?
        var startupMessage: String?
        do {
            let databaseURL = try configuration.databaseURL
                ?? Self.databaseURL(isDemoMode: isDemoMode)
            let repository = try SessionRepository(url: databaseURL)
            try repository.prepareAutomaticTimer(
                state: isDemoMode
                    ? BreakBarState()
                    : configuration.isUITestMode
                        ? BreakBarState()
                        : LegacyStatePersistence.load() ?? BreakBarState(),
                at: initialNow
            )
            restored = try repository.loadState() ?? BreakBarState()
            loadedRepository = repository
        } catch {
            startupMessage = "BreakBar could not open its timer database: \(error.localizedDescription)"
        }

        repository = loadedRepository
        engine = BreakBarEngine(state: restored, policy: initialPolicy)
        state = engine.state
        now = initialNow
        lastMessage = startupMessage
        launchAtLoginRequested = false
        launchAtLoginMessage = nil
        acceptedCallSignal = nil
        allowUncorrelatedBrowserCalls = UserDefaults.standard.bool(
            forKey: Self.allowUncorrelatedBrowserCallsKey
        )
        let initialBusyBarEnabled = configuration.allowsLiveIntegrations
            && UserDefaults.standard.bool(forKey: Self.busyBarEnabledKey)
        busyBarEnabled = initialBusyBarEnabled
        busyBarAddress = BusyBarAddress.normalized(
            UserDefaults.standard.string(forKey: Self.busyBarAddressKey)
                ?? BusyBarAddress.defaultUSB
        ) ?? BusyBarAddress.defaultUSB
        busyBarConnectionState = initialBusyBarEnabled ? .connecting : .off
        notificationAccessState = .unknown
        if !isUITestMode {
            refreshLaunchAtLoginStatus()
        }

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

        Publishers.CombineLatest3($state, $policy, $now)
            .sink { [weak self] values in
                self?.renderBusyBar(
                    BreakBarPresentation(
                        state: values.0,
                        policy: values.1,
                        now: values.2
                    ),
                    revision: values.0.revision
                )
            }
            .store(in: &observations)

        if !isUITestMode {
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

        if busyBarEnabled {
            configureBusyBar()
        }
    }

    deinit {
        ticker?.cancel()
        busyBarConnectionTask?.cancel()
        busyBarEventsTask?.cancel()
        busyBarCleanupTask?.cancel()
    }

    var presentation: BreakBarPresentation {
        BreakBarPresentation(state: state, policy: policy, now: now)
    }

    var canReturnEarly: Bool {
        guard state.phase == .onBreak else { return false }
        return (state.minimumBreakEndsAt ?? now) <= now
    }

    func performPrimaryAction() {
        switch state.phase {
        case .clockedOut:
            resumeReminders()
        case .focusing:
            if state.manualMeetingStartedAt != nil {
                apply(.endManualMeeting)
            } else {
                startBreak()
            }
        case .onBreak:
            returnToFocus()
        case .onLunch:
            resumeLegacyLunch()
        case .awayUnclassified:
            break
        case .traveling, .offsiteMeeting:
            returnHome()
        }
    }

    func resumeReminders() {
        let eventDate = isUITestMode ? now : Date()
        if apply(.resumeReminders, at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
    }

    func pauseReminders() {
        apply(.pauseReminders, at: isUITestMode ? now : Date())
    }

    func startBreak() {
        beginBreak(with: .startBreak)
    }

    func deferBreak() {
        let duration = isDemoMode ? policy.warningDuration : 5 * 60
        apply(.deferBreak(by: duration))
    }

    func resumeLegacyLunch() {
        let eventDate = Date()
        if apply(.endLunch, at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
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

    func showDiagnostics() {
        diagnosticsWindowController.show(
            snapshot: makeDiagnosticsSnapshot()
        ) { [weak self] in
            self?.showDiagnostics()
        }
    }

    private func makeDiagnosticsSnapshot() -> DiagnosticsSnapshot {
        let databaseStatus: DiagnosticsDatabaseStatus
        if let repository {
            do {
                databaseStatus = try repository.isHealthy() ? .healthy : .issueDetected
            } catch {
                databaseStatus = .issueDetected
            }
        } else {
            databaseStatus = .unavailable
        }

        let generatedAt = Date()
        let nextConstraint = calendarMonitor.schedulingConstraints
            .filter { $0.endAt > generatedAt }
            .min { $0.startAt < $1.startAt }
        let info = Bundle.main.infoDictionary

        return DiagnosticsSnapshotBuilder.make(
            from: DiagnosticsSnapshotInput(
                generatedAt: generatedAt,
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "Development",
                buildNumber: info?["CFBundleVersion"] as? String ?? "Local",
                isDemoMode: isDemoMode,
                state: state,
                notificationAccess: notificationAccessState,
                calendarAccess: calendarMonitor.accessState,
                selectedCalendarCount: calendarMonitor.selectedCalendarIDs.count,
                nextCalendarConstraint: nextConstraint,
                callMonitorStatus: callActivityMonitor.status,
                acceptedCallSignal: acceptedCallSignal,
                databaseStatus: databaseStatus,
                busyBarEnabled: busyBarEnabled,
                busyBarAddress: busyBarAddress,
                busyBarConnectionState: busyBarConnectionState,
                busyBarDeviceAPIVersion: busyBarDeviceAPIVersion,
                busyBarLastSuccessfulWriteAt: busyBarLastSuccessfulWriteAt,
                busyBarLastInputAt: busyBarLastInputAt
            )
        )
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func setNotificationAccessState(_ state: NotificationAccessState) {
        notificationAccessState = state
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

    func resetTimingPreferences() {
        replacePolicy(isDemoMode ? Self.demoPolicy : .standard)
    }

    func reconcileAfterLifecycleEvent() {
        let eventDate = Date()
        if !isUITestMode { calendarMonitor.refresh() }
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
        guard !isUITestMode else { return }
        let eventDate = Date()
        _ = apply(.updateCalendarConstraints(constraints), at: eventDate)
        _ = applyCurrentCallActivity(at: eventDate)
        _ = apply(.tick, at: eventDate)
    }

    private func callActivityChanged(_ signal: BreakCallSignal?) {
        guard !isUITestMode else { return }
        let eventDate = Date()
        _ = applyCurrentCallActivity(rawSignal: signal, at: eventDate)
        _ = applyCurrentCalendarConstraints(at: eventDate)
        _ = apply(.tick, at: eventDate)
    }

    @discardableResult
    private func updateIdleState(at date: Date) -> BreakCommandResult {
        observeActivity(idleDuration: IdleActivityMonitor.secondsSinceLastInput, at: date)
    }

    @discardableResult
    func observeActivity(idleDuration: TimeInterval, at date: Date) -> BreakCommandResult {
        let result = apply(.observeActivity(idleDuration: idleDuration), at: date, publishTime: false)
        if result == .changed {
            applyCurrentCalendarConstraints(at: date)
            applyCurrentCallActivity(at: date)
        }
        return result
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

    func setBusyBarEnabled(_ enabled: Bool) {
        guard enabled != busyBarEnabled else { return }
        busyBarEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.busyBarEnabledKey)
        configureBusyBar()
    }

    @discardableResult
    func setBusyBarAddress(_ address: String) -> Bool {
        guard let normalized = BusyBarAddress.normalized(address) else {
            return false
        }
        guard normalized != busyBarAddress else { return true }
        busyBarAddress = normalized
        UserDefaults.standard.set(normalized, forKey: Self.busyBarAddressKey)
        if busyBarEnabled {
            configureBusyBar()
        }
        return true
    }

    private static let allowUncorrelatedBrowserCallsKey =
        "call.allowUncorrelatedBrowserMicrophone"

    private static let focusDurationKey = "policy.focusDuration"
    private static let warningDurationKey = "policy.warningDuration"
    private static let minimumBreakDurationKey = "policy.minimumBreakDuration"
    private static let busyBarEnabledKey = "accessory.busyBar.enabled"
    private static let busyBarAddressKey = "accessory.busyBar.address"

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
        return BreakPolicy(
            focusDuration: focusDuration,
            warningDuration: warningDuration,
            minimumBreakDuration: minimumBreakDuration,
            maximumSeatedDuration: max(standard.maximumSeatedDuration, focusDuration),
            idleThreshold: standard.idleThreshold
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
    }

    private func configureBusyBar() {
        busyBarGeneration = UUID()
        busyBarRenderRequest = UUID()
        busyBarDeviceAPIVersion = nil
        busyBarLastSuccessfulWriteAt = nil
        busyBarLastInputAt = nil
        let generation = busyBarGeneration
        busyBarConnectionTask?.cancel()
        busyBarEventsTask?.cancel()
        busyBarConnectionTask = nil
        busyBarEventsTask = nil

        let previousAccessory = busyBarAccessory
        busyBarAccessory = nil
        let earlierCleanup = busyBarCleanupTask
        let cleanupTask = Task {
            await earlierCleanup?.value
            if let previousAccessory {
                await previousAccessory.disconnect()
            }
        }
        busyBarCleanupTask = cleanupTask

        guard busyBarEnabled,
              let baseURL = URL(string: busyBarAddress),
              let accessory = try? BusyBarAccessory(baseURL: baseURL)
        else {
            busyBarConnectionState = .off
            return
        }

        busyBarConnectionState = .connecting
        busyBarConnectionTask = Task { [weak self] in
            await cleanupTask.value
            guard let self,
                  !Task.isCancelled,
                  self.busyBarEnabled,
                  generation == self.busyBarGeneration
            else {
                return
            }

            self.busyBarAccessory = accessory
            self.busyBarEventsTask = Task { [weak self] in
                for await event in accessory.events() {
                    guard !Task.isCancelled else { return }
                    self?.handleBusyBarEvent(event, generation: generation)
                }
            }
            await self.connectBusyBar(accessory, generation: generation)
        }
    }

    private func connectBusyBar(
        _ accessory: BusyBarAccessory,
        generation: UUID
    ) async {
        var retryDelay = 1.0
        while !Task.isCancelled,
              busyBarEnabled,
              generation == busyBarGeneration
        {
            do {
                try await accessory.connect()
                guard !Task.isCancelled,
                      busyBarEnabled,
                      generation == busyBarGeneration
                else {
                    return
                }
                busyBarConnectionState = .connected
                await refreshBusyBarDiagnostics(accessory, generation: generation)
                renderBusyBar(presentation, revision: state.revision)
                return
            } catch {
                guard !Task.isCancelled,
                      busyBarEnabled,
                      generation == busyBarGeneration
                else {
                    return
                }
                busyBarConnectionState = .unavailable
            }

            do {
                try await Task.sleep(for: .seconds(retryDelay))
            } catch {
                return
            }
            retryDelay = min(30, retryDelay * 2)
            if generation == busyBarGeneration {
                busyBarConnectionState = .connecting
            }
        }
    }

    private func renderBusyBar(
        _ presentation: BreakBarPresentation,
        revision: UInt64
    ) {
        guard busyBarEnabled, let accessory = busyBarAccessory else { return }
        let generation = busyBarGeneration
        let renderRequest = UUID()
        busyBarRenderRequest = renderRequest
        Task { [weak self] in
            guard let self,
                  self.busyBarEnabled,
                  generation == self.busyBarGeneration,
                  renderRequest == self.busyBarRenderRequest
            else {
                return
            }

            do {
                try await accessory.render(presentation, revision: revision)
                await self.refreshBusyBarDiagnostics(accessory, generation: generation)
            } catch {
                guard self.busyBarEnabled,
                      generation == self.busyBarGeneration,
                      renderRequest == self.busyBarRenderRequest
                else {
                    return
                }
                self.busyBarConnectionState = .unavailable
            }
        }
    }

    private func handleBusyBarEvent(_ event: AccessoryEvent, generation: UUID) {
        guard busyBarEnabled, generation == busyBarGeneration else { return }

        if case .presenceChanged(let isPresent, _) = event {
            busyBarConnectionState = isPresent ? .connected : .unavailable
            return
        }

        if let accessory = busyBarAccessory {
            Task { [weak self] in
                await self?.refreshBusyBarDiagnostics(accessory, generation: generation)
            }
        }

        switch BusyBarEventRouting.command(for: event, state: state) {
        case .startBreak:
            startBreak()
        case .returnToFocus:
            returnToFocus()
        case nil:
            break
        default:
            break
        }
    }

    private func refreshBusyBarDiagnostics(
        _ accessory: BusyBarAccessory,
        generation: UUID
    ) async {
        let diagnostics = await accessory.diagnostics()
        guard generation == busyBarGeneration, accessory === busyBarAccessory else { return }
        busyBarDeviceAPIVersion = diagnostics.deviceAPIVersion
        busyBarLastSuccessfulWriteAt = diagnostics.lastSuccessfulWriteAt
        busyBarLastInputAt = diagnostics.lastInputAt
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
                lastMessage = "The timer database is unavailable, so the timer did not change."
                synchronizeWindows(at: eventDate)
                return .unchanged
            }
            do {
                try repository.commitTimerTransition(from: previousState, to: candidate.state)
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
                pauseReminders: { [weak self] in self?.pauseReminders() }
            )
        } else if state.phase == .focusing && state.enforcement == .required {
            overlayController.show(
                startBreak: { [weak self] in self?.startBreak() },
                canDeferBreak: state.canDeferBreak,
                deferBreakTitle: isDemoMode ? "15 more seconds" : "5 more minutes",
                deferBreak: { [weak self] in self?.deferBreak() },
                pauseReminders: { [weak self] in self?.pauseReminders() }
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
                pauseReminders: { [weak self] in self?.pauseReminders() }
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

enum BusyBarConnectionState: Equatable {
    case off
    case connecting
    case connected
    case unavailable

    var label: String {
        switch self {
        case .off:
            "Off"
        case .connecting:
            "Connecting…"
        case .connected:
            "Connected"
        case .unavailable:
            "Unavailable — retrying"
        }
    }
}

enum BusyBarAddress {
    static let defaultUSB = "http://10.0.4.20"

    static func normalized(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }
        components.scheme = scheme
        components.path = ""
        return components.url?.absoluteString
    }
}

enum BusyBarEventRouting {
    static func command(
        for event: AccessoryEvent,
        state: BreakBarState
    ) -> BreakCommand? {
        switch event {
        case .startBreak(_, let revision)
            where revision == state.revision && state.phase == .focusing:
            .startBreak
        case .returnToFocus(_, let revision)
            where revision == state.revision && state.phase == .onBreak:
            .returnToFocus
        default:
            nil
        }
    }
}
