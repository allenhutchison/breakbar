import BreakBarCore
import Foundation

struct DiagnosticsSnapshot: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        let title: String
        let rows: [Row]
    }

    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    let generatedAt: Date
    let sections: [Section]

    var report: String {
        var lines = [
            "BreakBar Diagnostics",
            "Generated: \(Self.timestamp(generatedAt))",
            "Privacy: Calendar titles and identifiers, call application identifiers, file paths, "
                + "device addresses, credentials, and raw errors are omitted.",
        ]

        for section in sections {
            lines.append("")
            lines.append("[\(section.title)]")
            lines.append(contentsOf: section.rows.map { "\($0.label): \($0.value)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum DiagnosticsDatabaseStatus: Equatable, Sendable {
    case healthy
    case issueDetected
    case unavailable
}

enum DiagnosticsExportStatus: Equatable, Sendable {
    case notConfigured
    case notAttempted
    case succeeded
    case failed
}

enum NotificationAccessState: Equatable, Sendable {
    case notDetermined
    case enabled
    case disabled
    case unknown

    var description: String {
        switch self {
        case .notDetermined: "Not requested"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }
}

struct DiagnosticsSnapshotInput: Sendable {
    let generatedAt: Date
    let appVersion: String
    let buildNumber: String
    let isDemoMode: Bool
    let state: BreakBarState
    let notificationAccess: NotificationAccessState
    let calendarAccess: CalendarAccessState
    let selectedCalendarCount: Int
    let nextCalendarConstraint: BreakCalendarConstraint?
    let callMonitorStatus: CallActivityMonitorStatus
    let acceptedCallSignal: BreakCallSignal?
    let databaseStatus: DiagnosticsDatabaseStatus
    let obsidianFolderURL: URL?
    let exportStatus: DiagnosticsExportStatus
    let busyBarEnabled: Bool
    let busyBarAddress: String
    let busyBarConnectionState: BusyBarConnectionState
    let busyBarDeviceAPIVersion: String?
    let busyBarLastSuccessfulWriteAt: Date?
    let busyBarLastInputAt: Date?
}

enum DiagnosticsSnapshotBuilder {
    static func make(from input: DiagnosticsSnapshotInput) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            generatedAt: input.generatedAt,
            sections: [
                appSection(input),
                timerSection(input),
                permissionsSection(input),
                calendarSection(input),
                callSection(input),
                storageSection(input),
                busyBarSection(input),
            ]
        )
    }

    private static func permissionsSection(
        _ input: DiagnosticsSnapshotInput
    ) -> DiagnosticsSnapshot.Section {
        .init(
            title: "Permissions",
            rows: [
                .init(label: "Notifications", value: input.notificationAccess.description),
                .init(label: "Calendar", value: input.calendarAccess.description),
            ]
        )
    }

    private static func appSection(_ input: DiagnosticsSnapshotInput) -> DiagnosticsSnapshot.Section {
        .init(
            title: "App",
            rows: [
                .init(label: "Version", value: "\(input.appVersion) (\(input.buildNumber))"),
                .init(label: "Mode", value: input.isDemoMode ? "Demo" : "Normal"),
            ]
        )
    }

    private static func timerSection(_ input: DiagnosticsSnapshotInput) -> DiagnosticsSnapshot.Section {
        .init(
            title: "Timer",
            rows: [
                .init(label: "Phase", value: phaseDescription(input.state.phase)),
                .init(label: "Enforcement", value: enforcementDescription(input.state.enforcement)),
                .init(label: "Revision", value: String(input.state.revision)),
                .init(label: "Phase started", value: timestamp(input.state.phaseStartedAt)),
                .init(label: "Nominal focus due", value: timestamp(input.state.nominalFocusDueAt)),
                .init(label: "Planned focus due", value: timestamp(input.state.focusDueAt)),
                .init(label: "Plan reason", value: planReasonDescription(input.state.breakPlanReason)),
                .init(
                    label: "Last transition",
                    value: transitionReasonDescription(input.state.lastTransitionReason)
                ),
            ]
        )
    }

    private static func calendarSection(
        _ input: DiagnosticsSnapshotInput
    ) -> DiagnosticsSnapshot.Section {
        let nextConstraint: String
        if let constraint = input.nextCalendarConstraint {
            nextConstraint = "\(constraintDescription(constraint.kind)), "
                + "\(timestamp(constraint.startAt)) to \(timestamp(constraint.endAt))"
        } else {
            nextConstraint = "None"
        }

        return .init(
            title: "Calendar",
            rows: [
                .init(label: "Selected calendars", value: String(input.selectedCalendarCount)),
                .init(label: "Next classified constraint", value: nextConstraint),
            ]
        )
    }

    private static func callSection(_ input: DiagnosticsSnapshotInput) -> DiagnosticsSnapshot.Section {
        let evidence: String
        if let signal = input.acceptedCallSignal {
            evidence = callConfidenceDescription(signal.confidence)
        } else {
            evidence = "None"
        }

        return .init(
            title: "Call detection",
            rows: [
                .init(label: "Detector", value: input.callMonitorStatus.description),
                .init(label: "Accepted evidence", value: evidence),
            ]
        )
    }

    private static func storageSection(
        _ input: DiagnosticsSnapshotInput
    ) -> DiagnosticsSnapshot.Section {
        .init(
            title: "Storage and export",
            rows: [
                .init(label: "Database", value: databaseDescription(input.databaseStatus)),
                .init(
                    label: "Obsidian folder",
                    value: input.obsidianFolderURL == nil ? "Not configured" : "Configured (path redacted)"
                ),
                .init(label: "Last export this launch", value: exportDescription(input.exportStatus)),
            ]
        )
    }

    private static func busyBarSection(
        _ input: DiagnosticsSnapshotInput
    ) -> DiagnosticsSnapshot.Section {
        let addressSource = input.busyBarAddress == BusyBarAddress.defaultUSB
            ? "Default USB"
            : "Custom (address redacted)"

        return .init(
            title: "BUSY Bar",
            rows: [
                .init(label: "Enabled", value: input.busyBarEnabled ? "Yes" : "No"),
                .init(label: "Address source", value: addressSource),
                .init(label: "Connection", value: input.busyBarConnectionState.label),
                .init(label: "Device API", value: input.busyBarDeviceAPIVersion ?? "Unknown"),
                .init(
                    label: "Last successful display write",
                    value: timestamp(input.busyBarLastSuccessfulWriteAt)
                ),
                .init(label: "Last input", value: timestamp(input.busyBarLastInputAt)),
            ]
        )
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date else { return "None" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func phaseDescription(_ phase: BreakBarPhase) -> String {
        switch phase {
        case .clockedOut: "Clocked out"
        case .focusing: "Focusing"
        case .onBreak: "On break"
        case .onLunch: "At lunch"
        case .awayUnclassified: "Away, awaiting classification"
        case .traveling: "Traveling"
        case .offsiteMeeting: "Offsite meeting"
        }
    }

    private static func enforcementDescription(_ enforcement: BreakEnforcement) -> String {
        switch enforcement {
        case .none: "None"
        case .warning: "Break warning"
        case .required: "Break required"
        case .travelWarning: "Travel warning"
        case .travelRequired: "Travel required"
        }
    }

    private static func planReasonDescription(_ reason: BreakPlanReason?) -> String {
        switch reason {
        case .nominal: "Nominal"
        case .pulledBeforeMeeting: "Pulled before meeting"
        case .deferredThroughMeeting: "Deferred through meeting"
        case .maximumSeatedLimit: "Maximum seated limit"
        case .postMeetingWarning: "Post-meeting warning"
        case .userDeferred: "User deferred"
        case nil: "None"
        }
    }

    private static func transitionReasonDescription(_ reason: BreakTransitionReason?) -> String {
        guard let reason else { return "None" }
        return words(from: reason.rawValue)
    }

    private static func constraintDescription(_ kind: BreakCalendarConstraintKind) -> String {
        switch kind {
        case .meeting: "Meeting"
        case .lunch: "Lunch"
        case .travel: "Travel"
        case .offsiteMeeting: "Offsite meeting"
        }
    }

    private static func callConfidenceDescription(_ confidence: BreakCallConfidence) -> String {
        switch confidence {
        case .dedicatedApplication: "Dedicated application active"
        case .calendarCorrelatedBrowser: "Calendar-correlated browser active"
        case .userApprovedBrowser: "User-approved browser active"
        }
    }

    private static func databaseDescription(_ status: DiagnosticsDatabaseStatus) -> String {
        switch status {
        case .healthy: "Healthy"
        case .issueDetected: "Issue detected"
        case .unavailable: "Unavailable"
        }
    }

    private static func exportDescription(_ status: DiagnosticsExportStatus) -> String {
        switch status {
        case .notConfigured: "Not configured"
        case .notAttempted: "Not attempted"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        }
    }

    private static func words(from rawValue: String) -> String {
        rawValue.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty {
                result.append(" ")
            }
            result.append(character)
        }
        .capitalized
    }
}
