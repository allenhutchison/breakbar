import AppKit
import BreakBarBusyBar
import BreakBarCore
import BreakBarExport
import BreakBarPersistence
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private enum ReturnPrompt {
        case lunch
        case travel
    }

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
    @Published private(set) var privacyDataMessage: String?
    @Published private(set) var privacyDataMessageIsError: Bool
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
    private let todayHistoryWindowController = TodayHistoryWindowController()
    private let diagnosticsWindowController = DiagnosticsWindowController()
    private let breakReturnPanelController = BreakReturnPanelController()
    private let awayReturnPanelController = AwayReturnPanelController()
    private let activityPromptPanelController = ActivityPromptPanelController()
    private var clockedOutReturnDetector = IdleReturnDetector()
    private var pausedReturnDetector = IdleReturnDetector()
    private var clockInPromptRequested = false
    private var returnPromptRequested: ReturnPrompt?
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
    private var lastObsidianExportAttemptSucceeded: Bool?
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
            try repository.bootstrapIfNeeded(
                state: isDemoMode
                    ? BreakBarState()
                    : configuration.isUITestMode
                        ? BreakBarState()
                        : LegacyStatePersistence.load() ?? BreakBarState(),
                at: initialNow
            )
            try Self.seedUITestScenario(
                configuration.uiTestScenario,
                in: repository,
                policy: initialPolicy,
                at: initialNow
            )
            restored = try repository.loadState() ?? BreakBarState()
            loadedRepository = repository
        } catch {
            startupMessage = "BreakBar could not open its history database: \(error.localizedDescription)"
        }

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
        privacyDataMessage = nil
        privacyDataMessageIsError = false
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
        returnPromptRequested = nil
        pausedReturnDetector.reset()
        apply(.clockOut)
    }

    func startBreak() {
        beginBreak(with: .startBreak)
    }

    func deferBreak() {
        let duration = isDemoMode ? policy.warningDuration : 5 * 60
        apply(.deferBreak(by: duration))
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
        let eventDate = isUITestMode ? now : Date()
        if apply(.classifyAway(classification), at: eventDate) == .changed {
            applyCurrentCalendarConstraints(at: eventDate)
            applyCurrentCallActivity(at: eventDate)
            _ = apply(.tick, at: eventDate)
            if isUITestMode {
                showTodayHistory()
            }
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

    func refreshTodayHistory() {
        refreshTodayHistory(at: isUITestMode ? now : Date())
    }

    func history(on date: Date) throws -> DailyHistory {
        guard let repository else {
            throw SessionRepositoryError.sqlite("The history database is unavailable.")
        }
        return try repository.dailyHistory(on: date)
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

    func canClockOutBeforeTravelReturn(_ interval: ActivityHistoryInterval) -> Bool {
        guard interval.kind == .travel,
              let returnedAt = interval.endedAt,
              let repository,
              let archive = try? repository.completeHistory(),
              archive.sessions.contains(where: {
                  $0.id == interval.sessionID
                      && ($0.endedAt.map { $0 > returnedAt } ?? true)
              })
        else { return false }
        return archive.intervals.contains {
            $0.sessionID == interval.sessionID
                && $0.kind == .focus
                && $0.startedAt == returnedAt
        }
    }

    func clockOutBeforeTravelReturn(
        _ interval: ActivityHistoryInterval,
        at clockedOutAt: Date
    ) throws {
        guard let repository else {
            throw SessionRepositoryError.sqlite("The history database is unavailable.")
        }
        let eventDate = Date()
        try repository.clockOutBeforeTravelReturn(
            travelIntervalID: interval.id,
            clockedOutAt: clockedOutAt,
            expectedState: state,
            correctedAt: eventDate
        )
        refreshTodayHistory()
        exportConfiguredHistory(
            on: [interval.startedAt, interval.endedAt, clockedOutAt].compactMap { $0 },
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

        let exportStatus: DiagnosticsExportStatus
        if obsidianDailyNotesFolderURL == nil {
            exportStatus = .notConfigured
        } else if let lastObsidianExportAttemptSucceeded {
            exportStatus = lastObsidianExportAttemptSucceeded ? .succeeded : .failed
        } else {
            exportStatus = .notAttempted
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
                obsidianFolderURL: obsidianDailyNotesFolderURL,
                exportStatus: exportStatus,
                busyBarEnabled: busyBarEnabled,
                busyBarAddress: busyBarAddress,
                busyBarConnectionState: busyBarConnectionState,
                busyBarDeviceAPIVersion: busyBarDeviceAPIVersion,
                busyBarLastSuccessfulWriteAt: busyBarLastSuccessfulWriteAt,
                busyBarLastInputAt: busyBarLastInputAt
            )
        )
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

    var canExportCompleteHistory: Bool {
        repository != nil
    }

    var canDeleteAllLocalHistory: Bool {
        repository != nil && state.phase == .clockedOut
    }

    func exportCompleteHistory() {
        guard let repository else {
            privacyDataMessage = "The history database is unavailable."
            privacyDataMessageIsError = true
            return
        }

        let exportDate = Date()
        let panel = NSSavePanel()
        panel.title = "Export Complete BreakBar History"
        panel.prompt = "Export"
        panel.nameFieldStringValue = Self.historyArchiveFilename(for: exportDate)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let archive = try repository.completeHistory(exportedAt: exportDate)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(archive)
            try data.write(to: destinationURL, options: .atomic)
            privacyDataMessage = "Exported \(archive.sessions.count) work sessions and "
                + "\(archive.intervals.count) activities."
            privacyDataMessageIsError = false
        } catch {
            privacyDataMessage = "History export failed: \(error.localizedDescription)"
            privacyDataMessageIsError = true
        }
    }

    func deleteAllLocalHistory() {
        guard state.phase == .clockedOut else {
            privacyDataMessage = SessionRepositoryError.historyDeletionRequiresClockedOut
                .localizedDescription
            privacyDataMessageIsError = true
            return
        }
        guard let repository else {
            privacyDataMessage = "The history database is unavailable."
            privacyDataMessageIsError = true
            return
        }

        do {
            let result = try repository.deleteAllHistory(expectedState: state)
            refreshTodayHistory()
            switch result {
            case .deleted:
                privacyDataMessage = "Deleted all local history. Settings and Obsidian notes were not changed."
                privacyDataMessageIsError = false
            case let .deletedWithCleanupWarning(message):
                privacyDataMessage = "History was deleted, but storage cleanup did not finish: \(message)"
                privacyDataMessageIsError = true
            }
        } catch {
            privacyDataMessage = "History could not be deleted: \(error.localizedDescription)"
            privacyDataMessageIsError = true
        }
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
        lastObsidianExportAttemptSucceeded = nil
        UserDefaults.standard.set(folderURL.path, forKey: Self.obsidianDailyNotesFolderKey)
        clearObsidianExportMessage()
    }

    func removeObsidianDailyNotesFolder() {
        obsidianDailyNotesFolderURL = nil
        lastObsidianExportAttemptSucceeded = nil
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
            lastObsidianExportAttemptSucceeded = false
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
            lastObsidianExportAttemptSucceeded = false
        } else if results.count == 1, let result = results.first {
            obsidianExportMessage = result.changed
                ? "Exported \(result.noteURL.lastPathComponent)."
                : "\(result.noteURL.lastPathComponent) is already up to date."
            obsidianExportMessageIsError = false
            lastObsidianExportAttemptSucceeded = true
        } else {
            let changedCount = results.count(where: \.changed)
            obsidianExportMessage = changedCount == 0
                ? "\(results.count) daily notes are already up to date."
                : "Exported \(changedCount) of \(results.count) daily notes."
            obsidianExportMessageIsError = false
            lastObsidianExportAttemptSucceeded = true
        }
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

    func presentSeededAwayReturnForUITest() {
        guard isUITestMode, state.phase == .awayUnclassified,
              state.awayReturnDetectedAt != nil else { return }
        synchronizeWindows(at: now, bringReturnPanelToFront: true)
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
        let idleDuration = IdleActivityMonitor.secondsSinceLastInput
        guard idleDuration.isFinite, idleDuration >= 0 else { return .unchanged }

        if clockedOutReturnDetector.update(
            isTracking: state.phase == .clockedOut,
            idleDuration: idleDuration,
            idleThreshold: policy.idleThreshold
        ) {
            clockInPromptRequested = true
            synchronizeWindows(at: date)
            return .changed
        }

        let tracksPausedReturn = state.phase == .onLunch
            || state.phase == .traveling
            || state.phase == .offsiteMeeting
        let travelCanReturn = state.travelChain?.allSatisfy { $0.endAt <= date } ?? false
        let canPromptForPausedReturn = state.phase == .onLunch || travelCanReturn
        if pausedReturnDetector.update(
            isTracking: tracksPausedReturn,
            canPrompt: canPromptForPausedReturn,
            idleDuration: idleDuration,
            idleThreshold: policy.idleThreshold
        ) {
            switch state.phase {
            case .onLunch:
                returnPromptRequested = .lunch
            case .traveling, .offsiteMeeting:
                returnPromptRequested = .travel
            case .clockedOut, .focusing, .onBreak, .awayUnclassified:
                break
            }
            synchronizeWindows(at: date)
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
    private static let idleThresholdKey = "policy.idleThreshold"
    private static let handledLunchPromptOccurrenceKey =
        "calendar.handledLunchPromptOccurrence"
    private static let obsidianDailyNotesFolderKey = "obsidian.dailyNotesFolder"
    private static let obsidianFilenameFormatKey = "obsidian.filenameFormat"
    private static let busyBarEnabledKey = "accessory.busyBar.enabled"
    private static let busyBarAddressKey = "accessory.busyBar.address"

    private static let demoPolicy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20,
        idleThreshold: 10
    )

    private static func seedUITestScenario(
        _ scenario: AppLaunchConfiguration.UITestScenario?,
        in repository: SessionRepository,
        policy: BreakPolicy,
        at referenceDate: Date
    ) throws {
        guard let scenario,
              try repository.completeHistory(exportedAt: referenceDate).sessions.isEmpty,
              let restored = try repository.loadState(),
              restored.phase == .clockedOut
        else {
            return
        }

        var engine = BreakBarEngine(state: restored, policy: policy)
        let commands: [(BreakCommand, Date)]
        switch scenario {
        case .settingsPrivacy:
            commands = [
                (.clockIn, referenceDate.addingTimeInterval(-60 * 60)),
                (.clockOut, referenceDate.addingTimeInterval(-30 * 60)),
            ]
        case .overnightTravelCorrection:
            let today = Calendar.current.startOfDay(for: referenceDate)
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            let clockedInAt = yesterday.addingTimeInterval(16 * 60 * 60)
            let travelStartsAt = yesterday.addingTimeInterval(20 * 60 * 60)
            let travelEndsAt = yesterday.addingTimeInterval(21 * 60 * 60)
            let travel = BreakCalendarConstraint(
                id: "ui-test-travel", startAt: travelStartsAt,
                endAt: travelEndsAt, kind: .travel
            )
            commands = [
                (.clockIn, clockedInAt),
                (.updateCalendarConstraints([travel]), clockedInAt),
                (.tick, travelStartsAt),
                (.returnHome, referenceDate.addingTimeInterval(-10 * 60)),
            ]
        case .awayClassification:
            commands = [
                (.clockIn, referenceDate.addingTimeInterval(-60 * 60)),
                (
                    .idleThresholdReached(idleStartedAt: referenceDate.addingTimeInterval(-120)),
                    referenceDate.addingTimeInterval(-60)
                ),
                (.userActivityResumed, referenceDate.addingTimeInterval(-1)),
            ]
        }
        for (command, date) in commands {
            let previous = engine.state
            var candidate = engine
            guard candidate.handle(command, at: date) == .changed else { continue }
            try repository.commitTransition(
                from: previous,
                to: candidate.state,
                at: date
            )
            engine = candidate
        }
    }

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
            refreshTodayHistory(at: eventDate)
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

    private static func historyArchiveFilename(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return "BreakBar History \(formatter.string(from: date)).json"
    }

    private func synchronizeWindows(
        at date: Date,
        bringReturnPanelToFront: Bool = false
    ) {
        if returnPromptRequested == .lunch, state.phase != .onLunch {
            returnPromptRequested = nil
        }
        if returnPromptRequested == .travel,
           state.phase != .traveling,
           state.phase != .offsiteMeeting
        {
            returnPromptRequested = nil
        }

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
        } else if state.phase == .onLunch && returnPromptRequested == .lunch {
            activityPromptPanelController.show(
                key: "return-from-lunch",
                title: "Welcome back",
                detail: "End lunch to begin a fresh focus cycle, or keep lunch active if you’re not ready yet.",
                symbolName: "figure.walk.arrival",
                accent: NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.16, alpha: 1),
                primaryTitle: "Return to focus",
                secondaryTitle: "Stay at lunch",
                primaryAction: { [weak self] in self?.endLunch() },
                secondaryAction: { [weak self] in self?.dismissReturnPrompt() }
            )
        } else if (state.phase == .traveling || state.phase == .offsiteMeeting)
            && returnPromptRequested == .travel
        {
            activityPromptPanelController.show(
                key: "return-from-travel",
                title: "Welcome home",
                detail: "Resume focus to end your away state and begin a fresh focus cycle.",
                symbolName: "house.fill",
                accent: NSColor(calibratedRed: 0.94, green: 0.48, blue: 0.12, alpha: 1),
                primaryTitle: "Resume focus",
                secondaryTitle: "Still away",
                primaryAction: { [weak self] in self?.returnHome() },
                secondaryAction: { [weak self] in self?.dismissReturnPrompt() }
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
                deferBreakTitle: isDemoMode ? "15 more seconds" : "5 more minutes",
                deferBreak: { [weak self] in self?.deferBreak() },
                clockOut: { [weak self] in self?.clockOut() }
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

    private func dismissReturnPrompt() {
        returnPromptRequested = nil
        pausedReturnDetector.reset()
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
