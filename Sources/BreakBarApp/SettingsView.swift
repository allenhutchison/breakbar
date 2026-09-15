import BreakBarCore
import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let checkForUpdates: () -> Void

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Timer source", value: "This Mac")

                if model.isDemoMode {
                    LabeledContent("Timing", value: "Accelerated demo")
                    Text("Timing controls are unavailable in demo mode so its seconds-long cycle remains intact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    MinuteInputRow(
                        title: "Focus interval",
                        minutes: Int(model.policy.focusDuration / 60),
                        range: 15 ... 99,
                        step: 5
                    ) { minutes in
                        model.setFocusDuration(TimeInterval(minutes * 60))
                    }

                    MinuteInputRow(
                        title: "Warning",
                        minutes: Int(model.policy.warningDuration / 60),
                        range: 1 ... min(15, Int(model.policy.focusDuration / 60)),
                        step: 1
                    ) { minutes in
                        model.setWarningDuration(TimeInterval(minutes * 60))
                    }

                    MinuteInputRow(
                        title: "Minimum break",
                        minutes: Int(model.policy.minimumBreakDuration / 60),
                        range: 1 ... 30,
                        step: 1
                    ) { minutes in
                        model.setMinimumBreakDuration(TimeInterval(minutes * 60))
                    }

                    MinuteInputRow(
                        title: "Idle-away threshold",
                        minutes: Int(model.policy.idleThreshold / 60),
                        range: 1 ... 60,
                        step: 1
                    ) { minutes in
                        model.setIdleThreshold(TimeInterval(minutes * 60))
                    }

                    Button("Restore timing defaults", action: model.resetTimingPreferences)
                        .disabled(model.policy == .standard)
                }

                Toggle(
                    "Launch BreakBar at login",
                    isOn: Binding(
                        get: { model.launchAtLoginRequested },
                        set: model.setLaunchAtLogin
                    )
                )

                if let message = model.launchAtLoginMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Login Items Settings", action: model.openLoginItemsSettings)
                            .buttonStyle(.link)
                    }
                }
            }

            CalendarSettingsSection(monitor: model.calendarMonitor)

            CallActivitySettingsSection(
                model: model,
                monitor: model.callActivityMonitor
            )

            ObsidianSettingsSection(model: model)

            BusyBarSettingsSection(model: model)

            Section("Updates") {
                Button("Check for Updates…", action: checkForUpdates)
                Text("BreakBar checks for updates automatically and installs downloaded updates when the app is ready to relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 720)
    }
}

private struct BusyBarSettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var address: String
    @State private var addressIsInvalid = false
    @FocusState private var addressIsFocused: Bool

    init(model: AppModel) {
        self.model = model
        _address = State(initialValue: model.busyBarAddress)
    }

    var body: some View {
        Section("BUSY Bar") {
            Toggle(
                "Use BUSY Bar accessory",
                isOn: Binding(
                    get: { model.busyBarEnabled },
                    set: model.setBusyBarEnabled
                )
            )

            LabeledContent("Connection", value: model.busyBarConnectionState.label)

            LabeledContent("Device address") {
                TextField("", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 190)
                    .focused($addressIsFocused)
                    .onSubmit(commitAddress)
                    .onChange(of: addressIsFocused) { _, focused in
                        if !focused { commitAddress() }
                    }
                    .onChange(of: model.busyBarAddress) { _, newAddress in
                        if !addressIsFocused {
                            address = newAddress
                            addressIsInvalid = false
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(addressIsInvalid ? Color.red : .clear, lineWidth: 1)
                    }
                    .accessibilityLabel("BUSY Bar device address")
                    .accessibilityHint("Enter an HTTP or HTTPS device address without a path.")
            }

            Text(
                "Connect the BUSY Bar over USB, then enable it here. "
                    + "BreakBar remains fully functional when the accessory is off or unavailable."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitAddress() {
        addressIsInvalid = !model.setBusyBarAddress(address)
        if !addressIsInvalid {
            address = model.busyBarAddress
        }
    }
}

private struct ObsidianSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Obsidian") {
            if model.isDemoMode {
                Text("Obsidian export is unavailable in demo mode so accelerated history never enters normal daily notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Daily notes folder", value: model.obsidianFolderDisplayName)

                HStack {
                    Button("Choose Folder", action: model.chooseObsidianDailyNotesFolder)
                    if model.obsidianDailyNotesFolderURL != nil {
                        Button("Remove", role: .destructive, action: model.removeObsidianDailyNotesFolder)
                    }
                }

                ObsidianNotePathFormatRow(model: model)
                LabeledContent("Example", value: model.obsidianFilenameExample)

                Button("Export Today Now", action: model.exportTodayHistory)
                    .disabled(!model.canExportToday)

                if let message = model.obsidianExportMessage {
                    Label(
                        message,
                        systemImage: model.obsidianExportMessageIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.obsidianExportMessageIsError ? Color.red : Color.secondary)
                }

                Text("BreakBar creates or replaces only its marked section. Exports also run after clock-out and history corrections; failures never block timer or history changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ObsidianNotePathFormatRow: View {
    @ObservedObject var model: AppModel
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(model: AppModel) {
        self.model = model
        _text = State(initialValue: model.obsidianFilenameFormat)
    }

    var body: some View {
        LabeledContent("Note path format") {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 170)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onChange(of: model.obsidianFilenameFormat) { _, format in
                    if !isFocused { text = format }
                }
                .help(formatHelpText)
                .accessibilityLabel("Note path format")
                .accessibilityHint(formatHelpText)
        }
    }

    private var formatHelpText: String {
        "Uses Apple date format symbols and may include subfolders. Quote literal folder names containing letters, for example 'Daily'/yyyy/MM/yyyy-MM-dd. The Markdown extension is added automatically."
    }

    private func commit() {
        if !model.setObsidianFilenameFormat(text) {
            text = model.obsidianFilenameFormat
        }
    }
}

private struct MinuteInputRow: View {
    let title: String
    let minutes: Int
    let range: ClosedRange<Int>
    let step: Int
    let onChange: (Int) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        title: String,
        minutes: Int,
        range: ClosedRange<Int>,
        step: Int,
        onChange: @escaping (Int) -> Void
    ) {
        self.title = title
        self.minutes = minutes
        self.range = range
        self.step = step
        self.onChange = onChange
        _text = State(initialValue: Self.format(minutes))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 38)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onChange(of: text) { _, newValue in
                        filterInput(newValue)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isInvalid ? Color.red : .clear, lineWidth: 1)
                    }
                    .accessibilityLabel(title)
                    .accessibilityHint("Enter a value from \(range.lowerBound) to \(range.upperBound) minutes.")

                Stepper("", value: stepperValue, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Adjust \(title.lowercased())")

                Text("min")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: minutes) { _, newValue in
            if !isFocused {
                text = Self.format(newValue)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commit()
            }
        }
    }

    private var stepperValue: Binding<Int> {
        Binding(
            get: { minutes },
            set: { newValue in
                let validated = min(range.upperBound, max(range.lowerBound, newValue))
                text = Self.format(validated)
                onChange(validated)
            }
        )
    }

    private var isInvalid: Bool {
        guard let value = Int(text) else { return !text.isEmpty }
        return !range.contains(value)
    }

    private func filterInput(_ newValue: String) {
        let filtered = String(newValue.filter(\.isNumber).prefix(2))
        if filtered != newValue {
            text = filtered
            return
        }

        guard let value = Int(filtered), range.contains(value) else { return }
        onChange(value)
    }

    private func commit() {
        guard let value = Int(text) else {
            text = Self.format(minutes)
            return
        }

        let validated = min(range.upperBound, max(range.lowerBound, value))
        text = Self.format(validated)
        onChange(validated)
    }

    private static func format(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}

private struct CallActivitySettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: CallActivityMonitor

    var body: some View {
        Section("Live meetings") {
            LabeledContent("Detection", value: monitor.status.description)

            Toggle(
                "Treat browser microphone use as a meeting",
                isOn: Binding(
                    get: { model.allowUncorrelatedBrowserCalls },
                    set: model.setAllowUncorrelatedBrowserCalls
                )
            )
            Text("Enable this for ad-hoc Google Meet calls. Other browser recording or voice features may also count as meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let applicationName = model.activeCallApplicationName {
                LabeledContent("Active call", value: applicationName)
                if let confidence = model.acceptedCallSignal?.confidence {
                    LabeledContent(
                        "Confidence",
                        value: confidenceDescription(confidence)
                    )
                }
            } else if monitor.signal != nil {
                Text("Browser microphone activity is only treated as a meeting when it is near an event on a selected calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No recognized call is active.")
                    .foregroundStyle(.secondary)
            }

            if case let .unavailable(message) = monitor.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("BreakBar checks which recognized app is using microphone input. It never records or listens to audio, and falls back to calendar scheduling if detection is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func confidenceDescription(_ confidence: BreakCallConfidence) -> String {
        switch confidence {
        case .dedicatedApplication:
            "High · dedicated app"
        case .calendarCorrelatedBrowser:
            "Medium · calendar correlated"
        case .userApprovedBrowser:
            "Medium · browser rule"
        }
    }
}

private struct CalendarSettingsSection: View {
    @ObservedObject var monitor: CalendarMonitor

    var body: some View {
        Section("Calendar") {
            LabeledContent("Access", value: monitor.accessState.description)

            switch monitor.accessState {
            case .notDetermined:
                Button("Connect Calendar", action: monitor.requestAccess)

            case .fullAccess:
                if monitor.calendars.isEmpty {
                    Text("No event calendars are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.calendars) { calendar in
                        Toggle(
                            isOn: Binding(
                                get: { monitor.isCalendarSelected(calendar.id) },
                                set: { monitor.setCalendar(calendar.id, included: $0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(calendar.title)
                                Text(calendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

            case .denied, .restricted, .writeOnly:
                Text("BreakBar needs full read access to plan around meetings. Update Calendar access in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .unknown:
                Text("Calendar permission status is unavailable.")
                    .foregroundStyle(.secondary)
            }

            if let message = monitor.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
