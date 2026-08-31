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

            Section("Accessories") {
                Text("No accessories installed")
                Text("BUSY Bar support will be added as an optional plugin after hardware validation.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 560)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        return "\(Int(seconds / 60)) minutes"
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
