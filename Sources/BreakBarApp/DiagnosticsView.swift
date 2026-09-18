import AppKit
import SwiftUI

struct DiagnosticsView: View {
    let snapshot: DiagnosticsSnapshot
    let refresh: () -> Void

    @State private var copyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
                Text("Sensitive calendar, application, file, network, and credential details are omitted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(snapshot.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)

                            ForEach(section.rows, id: \.label) { row in
                                LabeledContent(row.label) {
                                    Text(row.value)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            HStack {
                Button("Refresh", action: refresh)
                Button("Copy Diagnostics", action: copyDiagnostics)
                    .buttonStyle(.borderedProminent)

                if let copyMessage {
                    Text(copyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Text("Generated \(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 620)
    }

    private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(snapshot.report, forType: .string) {
            copyMessage = "Copied"
        } else {
            copyMessage = "Could not copy"
        }
    }
}
