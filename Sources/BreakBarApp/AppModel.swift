import AppKit
import BreakBarCore
import BreakBarExport
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
    @Published private(set) var todayHistory: DailyHistory?
    @Published private(set) var historyMessage: String?
    @Published private(set) var obsidianDailyNotesFolderURL: URL?
    @Published private(set) var obsidianFilenameFormat: String
    @Published private(set) var obsidianExportMessage: String?
    @Published private(set) var obsidianExportMessageIsError: Bool

    let isDemoMode: Bool
    let calendarMonitor = CalendarMonitor()
    let callActivityMonitor = CallActivityMonitor()

    private var engine: BreakBarEngine
    private let repository: SessionRepository?
    private let overlayController = OverlayController()
    private let todayHistoryWindowController = TodayHistoryWindowController()
    private let breakReturnPanelController = BreakReturnPanelController()
    private let awayReturnPanelController = AwayReturnPanelController()
    private let activityPromptPanelController = ActivityPromptPanelController()
    private var clockedOutReturnDetector = ClockedOutReturnDetector()
    private var clockInPromptRequested = false
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

        let initialNow = Date()
        var initialHistory: DailyHistory?
        var initialHistoryMessage: String?
        if let loadedRepository {
            do {
                initialHistory = try loadedRepository.dailyHistory(on: initialNow)
            } catch {
                initialHistoryMessage = "BreakBar could not load today’s history: \(error.localizedDescription)"
            }
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
        todayHistory = initialHistory
        historyMessage = initialHistoryMessage
        obsidianDailyNotesFolderURL = UserDefaults.standard.string(
            forKey: Self.obsidianDailyNotesFolderKey
        ).map { URL(fileURLWithPath: $0, isDirectory: true) }
        obsidianFilenameFormat = UserDefaults.standard.string(
            forKey: Self.obsidianFilenameFormatKey
        ) ?? ObsidianExporter.defaultFilenameFormat
        obsidianExportMessage = nil
        obsidianExportMessageIsError = false
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

    var canReturnEarly: Bool {
        guard state.phase == .onBreak else { return false }
        return (state.minimumBreakEndsAt ?? now) <= now
    }

    var preferredAwayClassification: AwayClassification? {
        guard state.phase == .awayUnclassified,
              let awayStartedAt = state.phaseStartedAt,
              let returnedAt = state.awayReturnDetectedAt
        else {
            return nil
        }
        return BreakLunchPlanner.preferredAwayClassification(
            in: calendarMonitor.schedulingConstraints,
            awayStartedAt: awayStartedAt,
            returnedAt: returnedAt
        )
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
            clockInPromptRequested = false
            clockedOutReturnDetector.reset()
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
        }
    }

    func clockOut() {
        clockInPromptRequested = false
        clockedOutReturnDetector.reset()
        apply(.clockOut)
    }

    func emergencyClockOut() {
        apply(.emergencyClockOut)
    }

    func startBreak() {
        beginBreak(with: .startBreak)
    }

    func startLunch() {
        let eventDate = Date()
        let calendarLunch = BreakLunchPlanner.promptCandidate(
            in: calendarMonitor.schedulingConstraints,
            at: eventDate
        )
        if apply(.startLunch, at: eventDate) == .changed,
           let calendarLunch
        {
            markLunchPromptHandled(calendarLunch)
        }
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

    func refreshTodayHistory() {
        refreshTodayHistory(at: Date())
    }

    func correctHistoryInterval(
        _ interval: ActivityHistoryInterval,
        kind: ActivityKind,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let eventDate = Date()
        guard let repository else {
            throw SessionRepositoryError.sqlite("The history database is unavailable.")
        }
        try repository.correctInterval(
            id: interval.id,
            kind: kind,
            startedAt: startedAt,
            endedAt: endedAt,
            correctedAt: eventDate
        )
        refreshTodayHistory()
        exportConfiguredHistory(
            on: [interval.startedAt, interval.endedAt, startedAt, endedAt].compactMap { $0 },
            at: eventDate
        )
    }

    func correctWorkSession(
        _ session: WorkSessionHistory,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let eventDate = Date()
        guard let repository else {
            throw SessionRepositoryError.sqlite("The history database is unavailable.")
        }
        try repository.correctWorkSession(
            id: session.id,
            startedAt: startedAt,
            endedAt: endedAt,
            correctedAt: eventDate
        )
        refreshTodayHistory()
        exportConfiguredHistory(
            on: [session.startedAt, session.endedAt, startedAt, endedAt].compactMap { $0 },
            at: eventDate
        )
    }

    func correctActiveWorkSessionClockIn(
        _ session: WorkSessionHistory,
        startedAt: Date
    ) throws {
        let eventDate = Date()
        guard startedAt < eventDate else {
            throw SessionRepositoryError.invalidActiveSessionStart
        }
        guard let repository else {
            throw SessionRepositoryError.sqlite("The history database is unavailable.")
        }

        let previousState = engine.state
        let adjustsCurrentFocusCycle = try repository
            .isOpenWorkSessionInInitialFocusCycle(id: session.id)
        var candidate = engine
        guard candidate.handle(
            .correctClockIn(
                from: session.startedAt,
                to: startedAt,
                adjustsCurrentFocusCycle: adjustsCurrentFocusCycle
            ),
            at: eventDate
        ) == .changed else {
            throw SessionRepositoryError.sessionIsNotOpen
        }

        try repository.correctOpenWorkSessionStart(
            id: session.id,
            from: previousState,
            to: candidate.state,
            startedAt: startedAt,
            correctedAt: eventDate
        )
        engine = candidate
        state = candidate.state
        now = eventDate
        lastMessage = nil
        refreshTodayHistory()
        exportConfiguredHistory(
            on: [session.startedAt, startedAt, eventDate],
            at: eventDate
        )

        if state.phase == .focusing {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
            _ = apply(.tick, at: eventDate)
        } else {
            synchronizeWindows(at: eventDate)
        }
    }

    func showTodayHistory() {
        refreshTodayHistory()
        todayHistoryWindowController.show(model: self)
    }

    private func refreshTodayHistory(at date: Date) {
        guard let repository else {
            todayHistory = nil
            historyMessage = "The history database is unavailable."
            return
        }
        do {
            todayHistory = try repository.dailyHistory(on: date)
            historyMessage = nil
        } catch {
            todayHistory = nil
            historyMessage = "BreakBar could not load today’s history: \(error.localizedDescription)"
        }
    }

    var obsidianFolderDisplayName: String {
        obsidianDailyNotesFolderURL?.lastPathComponent ?? "Not selected"
    }

    var obsidianFilenameExample: String {
        do {
            let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
            let noteURL = try ObsidianExporter().noteURL(
                for: now,
                in: rootURL,
                filenameFormat: obsidianFilenameFormat
            )
            return String(noteURL.path.dropFirst(rootURL.path.count))
        } catch {
            return "Invalid format"
        }
    }

    var canExportToday: Bool {
        !isDemoMode && obsidianDailyNotesFolderURL != nil && todayHistory != nil
    }

    func chooseObsidianDailyNotesFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Obsidian Daily Notes Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let folderURL = selectedURL.standardizedFileURL
        obsidianDailyNotesFolderURL = folderURL
        UserDefaults.standard.set(folderURL.path, forKey: Self.obsidianDailyNotesFolderKey)
        clearObsidianExportMessage()
    }

    func removeObsidianDailyNotesFolder() {
        obsidianDailyNotesFolderURL = nil
        UserDefaults.standard.removeObject(forKey: Self.obsidianDailyNotesFolderKey)
        clearObsidianExportMessage()
    }

    @discardableResult
    func setObsidianFilenameFormat(_ format: String) -> Bool {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try ObsidianExporter().noteURL(
                for: now,
                in: URL(fileURLWithPath: "/", isDirectory: true),
                filenameFormat: trimmed
            )
            obsidianFilenameFormat = trimmed
            UserDefaults.standard.set(trimmed, forKey: Self.obsidianFilenameFormatKey)
            clearObsidianExportMessage()
            return true
        } catch {
            obsidianExportMessage = error.localizedDescription
            obsidianExportMessageIsError = true
            return false
        }
    }

    func exportTodayHistory() {
        guard !isDemoMode else {
            obsidianExportMessage = "Demo history is kept separate and cannot be exported."
            obsidianExportMessageIsError = true
            return
        }
        guard obsidianDailyNotesFolderURL != nil else {
            obsidianExportMessage = "Choose an Obsidian daily-notes folder first."
            obsidianExportMessageIsError = true
            return
        }
        exportConfiguredHistory(on: Date())
    }

    func clearObsidianExportMessage() {
        obsidianExportMessage = nil
        obsidianExportMessageIsError = false
    }

    private func exportConfiguredHistory(on date: Date) {
        exportConfiguredHistory(on: [date], at: date)
    }

    private func exportConfiguredHistory(on dates: [Date], at exportDate: Date) {
        guard !isDemoMode, let folderURL = obsidianDailyNotesFolderURL else { return }
        guard let repository else {
            let message = "The history database is unavailable."
            obsidianExportMessage = message
            obsidianExportMessageIsError = true
            lastMessage = "Obsidian export failed: \(message)"
            return
        }

        let days = ObsidianExportDaySelection.days(containing: dates)
        var results: [ObsidianExportResult] = []
        var failures: [Error] = []
        for day in days {
            do {
                let history = try repository.dailyHistory(on: day)
                results.append(
                    try ObsidianExporter().export(
                        history: history,
                        at: exportDate,
                        to: folderURL,
                        filenameFormat: obsidianFilenameFormat
                    )
                )
            } catch {
                failures.append(error)
            }
        }

        if let firstFailure = failures.first {
            let message = failures.count == 1
                ? firstFailure.localizedDescription
                : "\(failures.count) daily notes could not be exported. \(firstFailure.localizedDescription)"
            obsidianExportMessage = message
            obsidianExportMessageIsError = true
            lastMessage = "Obsidian export failed: \(message)"
        } else if results.count == 1, let result = results.first {
            obsidianExportMessage = result.changed
                ? "Exported \(result.noteURL.lastPathComponent)."
                : "\(result.noteURL.lastPathComponent) is already up to date."
            obsidianExportMessageIsError = false
        } else {
            let changedCount = results.count(where: \.changed)
            obsidianExportMessage = changedCount == 0
                ? "\(results.count) daily notes are already up to date."
                : "Exported \(changedCount) of \(results.count) daily notes."
            obsidianExportMessageIsError = false
        }
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
        if let todayHistory, !todayHistory.contains(eventDate) {
            refreshTodayHistory(at: eventDate)
        }
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

        if clockedOutReturnDetector.update(
            isClockedOut: state.phase == .clockedOut,
            idleDuration: idleDuration,
            idleThreshold: policy.idleThreshold
        ) {
            clockInPromptRequested = true
            return .changed
        }

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
    private static let handledLunchPromptOccurrenceKey =
        "calendar.handledLunchPromptOccurrence"
    private static let obsidianDailyNotesFolderKey = "obsidian.dailyNotesFolder"
    private static let obsidianFilenameFormatKey = "obsidian.filenameFormat"

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
            refreshTodayHistory()
            if previousState.phase != .clockedOut, state.phase == .clockedOut {
                exportConfiguredHistory(on: eventDate)
            }
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
        let lunchPrompt = lunchPromptCandidate(at: date)
        if let lunchPrompt {
            overlayController.hide()
            activityPromptPanelController.show(
                key: "lunch|\(Self.lunchOccurrenceKey(lunchPrompt))",
                title: "Lunch is on your calendar",
                detail: "Start lunch to pause break reminders. Ending lunch begins a fresh focus interval.",
                symbolName: "fork.knife",
                accent: NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.16, alpha: 1),
                primaryTitle: "Start lunch",
                secondaryTitle: "Keep working",
                primaryAction: { [weak self] in
                    self?.acceptCalendarLunch(lunchPrompt)
                },
                secondaryAction: { [weak self] in
                    self?.dismissCalendarLunch(lunchPrompt)
                }
            )
        } else if state.phase == .clockedOut && clockInPromptRequested {
            activityPromptPanelController.show(
                key: "clock-in",
                title: "Ready to work?",
                detail: "You’re active again while BreakBar is clocked out. Clock in to start tracking focus time.",
                symbolName: "sun.max.fill",
                accent: NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.88, alpha: 1),
                primaryTitle: "Clock in",
                secondaryTitle: "Not yet",
                primaryAction: { [weak self] in self?.clockIn() },
                secondaryAction: { [weak self] in self?.dismissClockInPrompt() }
            )
        } else {
            activityPromptPanelController.hide()
        }

        if lunchPrompt != nil {
            overlayController.hide()
        } else if state.phase == .traveling && state.enforcement == .travelRequired {
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
                preferredClassification: preferredAwayClassification,
                classify: { [weak self] classification in
                    self?.classifyAway(as: classification)
                },
                clockOut: { [weak self] in self?.clockOut() }
            )
        } else {
            awayReturnPanelController.hide()
        }
    }

    private func lunchPromptCandidate(at date: Date) -> BreakCalendarConstraint? {
        guard state.phase == .focusing,
              state.manualMeetingStartedAt == nil,
              state.liveCallStartedAt == nil,
              state.enforcement != .travelWarning,
              !calendarMonitor.schedulingConstraints.contains(where: {
                  $0.kind == .meeting && $0.startAt <= date && date < $0.endAt
              }),
              let candidate = BreakLunchPlanner.promptCandidate(
                  in: calendarMonitor.schedulingConstraints,
                  at: date
              )
        else {
            return nil
        }

        let handledOccurrence = UserDefaults.standard.string(
            forKey: Self.handledLunchPromptOccurrenceKey
        )
        return handledOccurrence == Self.lunchOccurrenceKey(candidate) ? nil : candidate
    }

    private func acceptCalendarLunch(_ lunch: BreakCalendarConstraint) {
        let eventDate = Date()
        if apply(.startLunch, at: eventDate) == .changed {
            markLunchPromptHandled(lunch)
        }
    }

    private func dismissCalendarLunch(_ lunch: BreakCalendarConstraint) {
        markLunchPromptHandled(lunch)
        let eventDate = Date()
        now = eventDate
        synchronizeWindows(at: eventDate)
    }

    private func dismissClockInPrompt() {
        clockInPromptRequested = false
        clockedOutReturnDetector.reset()
        let eventDate = Date()
        now = eventDate
        synchronizeWindows(at: eventDate)
    }

    private func markLunchPromptHandled(_ lunch: BreakCalendarConstraint) {
        UserDefaults.standard.set(
            Self.lunchOccurrenceKey(lunch),
            forKey: Self.handledLunchPromptOccurrenceKey
        )
    }

    private static func lunchOccurrenceKey(_ lunch: BreakCalendarConstraint) -> String {
        "\(lunch.id)|\(lunch.startAt.timeIntervalSinceReferenceDate)"
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

enum ObsidianExportDaySelection {
    static func days(
        containing dates: [Date],
        calendar: Calendar = .current
    ) -> [Date] {
        Array(Set(dates.map(calendar.startOfDay(for:)))).sorted()
    }
}
