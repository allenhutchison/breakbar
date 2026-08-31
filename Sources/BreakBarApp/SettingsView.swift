import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Timer source", value: "This Mac")
            LabeledContent("Focus interval", value: duration(model.policy.focusDuration))
            LabeledContent("Warning", value: duration(model.policy.warningDuration))
            LabeledContent("Minimum break", value: duration(model.policy.minimumBreakDuration))

            Section("Accessories") {
                Text("No accessories installed")
                Text("BUSY Bar support will be added as an optional plugin after hardware validation.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 330)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        return "\(Int(seconds / 60)) minutes"
    }
}
