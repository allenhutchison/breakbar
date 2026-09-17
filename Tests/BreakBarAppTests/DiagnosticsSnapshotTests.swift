import BreakBarCore
import Foundation
import XCTest
@testable import BreakBarApp

final class DiagnosticsSnapshotTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testReportIncludesOperationalHealthWithoutSensitiveValues() {
        let privateCalendarIdentifier = "calendar-secret-identifier"
        let privateBundleIdentifier = "com.example.private-call-app"
        let privateFolder = "/Users/example/Private Vault/Clients/Acme"
        let privateDeviceAddress = "https://breakbar-device.private.example:8443"
        let state = BreakBarState(
            phase: .focusing,
            enforcement: .warning,
            phaseStartedAt: generatedAt.addingTimeInterval(-600),
            nominalFocusDueAt: generatedAt.addingTimeInterval(300),
            focusDueAt: generatedAt.addingTimeInterval(600),
            breakPlanReason: .deferredThroughMeeting,
            liveCallStartedAt: generatedAt.addingTimeInterval(-60),
            liveCallBundleIdentifier: privateBundleIdentifier,
            liveCallConfidence: .dedicatedApplication,
            lastTransitionReason: .liveCallStarted,
            revision: 42
        )
        let report = DiagnosticsSnapshotBuilder.make(
            from: DiagnosticsSnapshotInput(
                generatedAt: generatedAt,
                appVersion: "1.2.3",
                buildNumber: "45",
                isDemoMode: false,
                state: state,
                notificationAccess: .enabled,
                calendarAccess: .fullAccess,
                selectedCalendarCount: 3,
                nextCalendarConstraint: BreakCalendarConstraint(
                    id: privateCalendarIdentifier,
                    startAt: generatedAt.addingTimeInterval(900),
                    endAt: generatedAt.addingTimeInterval(1_800),
                    kind: .offsiteMeeting
                ),
                callMonitorStatus: .monitoring,
                acceptedCallSignal: BreakCallSignal(
                    bundleIdentifier: privateBundleIdentifier,
                    confidence: .dedicatedApplication
                ),
                databaseStatus: .healthy,
                obsidianFolderURL: URL(fileURLWithPath: privateFolder),
                exportStatus: .succeeded,
                busyBarEnabled: true,
                busyBarAddress: privateDeviceAddress,
                busyBarConnectionState: .connected,
                busyBarDeviceAPIVersion: "27.5.0",
                busyBarLastSuccessfulWriteAt: generatedAt.addingTimeInterval(-2),
                busyBarLastInputAt: generatedAt.addingTimeInterval(-1)
            )
        ).report

        XCTAssertTrue(report.contains("Version: 1.2.3 (45)"))
        XCTAssertTrue(report.contains("Revision: 42"))
        XCTAssertTrue(report.contains("Plan reason: Deferred through meeting"))
        XCTAssertTrue(report.contains("Notifications: Enabled"))
        XCTAssertTrue(report.contains("Calendar: Connected"))
        XCTAssertTrue(report.contains("Next classified constraint: Offsite meeting"))
        XCTAssertTrue(report.contains("Accepted evidence: Dedicated application active"))
        XCTAssertTrue(report.contains("Database: Healthy"))
        XCTAssertTrue(report.contains("Obsidian folder: Configured (path redacted)"))
        XCTAssertTrue(report.contains("Address source: Custom (address redacted)"))
        XCTAssertTrue(report.contains("Device API: 27.5.0"))

        XCTAssertFalse(report.contains(privateCalendarIdentifier))
        XCTAssertFalse(report.contains(privateBundleIdentifier))
        XCTAssertFalse(report.contains(privateFolder))
        XCTAssertFalse(report.contains("Private Vault"))
        XCTAssertFalse(report.contains(privateDeviceAddress))
        XCTAssertFalse(report.contains("private.example"))
    }

    func testReportDescribesDisabledAndUnconfiguredIntegrations() {
        let report = DiagnosticsSnapshotBuilder.make(
            from: DiagnosticsSnapshotInput(
                generatedAt: generatedAt,
                appVersion: "Development",
                buildNumber: "Local",
                isDemoMode: true,
                state: BreakBarState(),
                notificationAccess: .disabled,
                calendarAccess: .denied,
                selectedCalendarCount: 0,
                nextCalendarConstraint: nil,
                callMonitorStatus: .unavailable("private raw error"),
                acceptedCallSignal: nil,
                databaseStatus: .unavailable,
                obsidianFolderURL: nil,
                exportStatus: .notConfigured,
                busyBarEnabled: false,
                busyBarAddress: BusyBarAddress.defaultUSB,
                busyBarConnectionState: .off,
                busyBarDeviceAPIVersion: nil,
                busyBarLastSuccessfulWriteAt: nil,
                busyBarLastInputAt: nil
            )
        ).report

        XCTAssertTrue(report.contains("Mode: Demo"))
        XCTAssertTrue(report.contains("Notifications: Disabled"))
        XCTAssertTrue(report.contains("Calendar: Denied"))
        XCTAssertTrue(report.contains("Detector: Calendar only"))
        XCTAssertTrue(report.contains("Database: Unavailable"))
        XCTAssertTrue(report.contains("Obsidian folder: Not configured"))
        XCTAssertTrue(report.contains("Address source: Default USB"))
        XCTAssertTrue(report.contains("Last input: None"))
        XCTAssertFalse(report.contains("private raw error"))
    }
}
