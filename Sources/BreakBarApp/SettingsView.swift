import BreakBarCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Timer source", value: "This Mac")
                LabeledContent("Focus interval", value: duration(model.policy.focusDuration))
                LabeledContent("Warning", value: duration(model.policy.warningDuration))
                LabeledContent("Minimum break", value: duration(model.policy.minimumBreakDuration))
                LabeledContent("Idle-away threshold", value: duration(model.policy.idleThreshold))

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

            Section("Accessories") {
                Text("No accessories installed")
                Text("BUSY Bar support will be added as an optional plugin after hardware validation.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 680)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        return "\(Int(seconds / 60)) minutes"
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
