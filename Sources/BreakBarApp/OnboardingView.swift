import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let requestNotificationAccess: () -> Void
    let finish: () -> Void

    @State private var progress = OnboardingProgress()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    BreakLoopDiagram()
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(32)
            }

            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 580)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.stand")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Set up BreakBar")
                    .font(.title2.weight(.semibold))
                Text("Step \(progress.position) of \(OnboardingStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProgressView(
                value: Double(progress.position),
                total: Double(OnboardingStep.allCases.count)
            )
            .frame(width: 150)
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(progress.position) of \(OnboardingStep.allCases.count)")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch progress.step {
        case .welcome:
            welcomeStep
        case .notifications:
            notificationsStep
        case .calendar:
            calendarStep
        case .obsidian:
            obsidianStep
        case .options:
            optionsStep
        case .ready:
            readyStep
        }
    }

    private var welcomeStep: some View {
        OnboardingStepLayout(
            title: "A break timer that respects the work around it",
            detail: "BreakBar stays in the menu bar, plans around meetings, "
                + "and keeps the Mac in charge of every timer and transition."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingFeature(
                    symbol: "macbook",
                    title: "Complete without accessories",
                    detail: "The Mac always provides the timer, controls, history, and safety escape."
                )
                OnboardingFeature(
                    symbol: "hand.raised.fill",
                    title: "Deliberate by design",
                    detail: "Breaks start and end only when you choose. Closing a window never quits BreakBar."
                )
                OnboardingFeature(
                    symbol: "lock.shield.fill",
                    title: "Local and inspectable",
                    detail: "History stays in a local database. Calendar titles and microphone audio are not stored."
                )
            }
        }
    }

    private var notificationsStep: some View {
        OnboardingStepLayout(
            title: "Hear the warning before a break",
            detail: "BreakBar uses one notification and one sound when the warning period begins. "
                + "The timer still works if notifications are unavailable."
        ) {
            GroupBox {
                HStack(spacing: 16) {
                    Image(systemName: notificationSymbol)
                        .font(.system(size: 28))
                        .foregroundStyle(notificationColor)
                        .frame(width: 36)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notifications")
                            .font(.headline)
                        Text(notificationDescription)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if model.notificationAccessState == .notDetermined {
                        Button("Enable Notifications", action: requestNotificationAccess)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(8)
            }

            if model.notificationAccessState == .disabled {
                Text("Notifications are disabled. You can enable BreakBar later in System Settings → Notifications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var calendarStep: some View {
        OnboardingStepLayout(
            title: "Plan around your calendar",
            detail: "Calendar access lets BreakBar move breaks around meetings, lunch, and travel. "
                + "It reads selected calendars and never edits events."
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        LabeledContent(
                            "Calendar access",
                            value: model.calendarMonitor.accessState.description
                        )
                        Spacer()
                        if model.calendarMonitor.accessState == .notDetermined {
                            Button(
                                "Connect Calendar",
                                action: model.calendarMonitor.requestAccess
                            )
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if model.calendarMonitor.accessState == .fullAccess {
                        Divider()
                        Text("Included calendars")
                            .font(.headline)

                        if model.calendarMonitor.calendars.isEmpty {
                            Text("No event calendars are available.")
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.calendarMonitor.calendars) { calendar in
                                        Toggle(
                                            isOn: Binding(
                                                get: {
                                                    model.calendarMonitor.isCalendarSelected(
                                                        calendar.id
                                                    )
                                                },
                                                set: {
                                                    model.calendarMonitor.setCalendar(
                                                        calendar.id,
                                                        included: $0
                                                    )
                                                }
                                            )
                                        ) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(calendar.title)
                                                Text(calendar.sourceTitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }
                    } else if model.calendarMonitor.accessState != .notDetermined {
                        Text("BreakBar will use its normal timer until full Calendar access is available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let message = model.calendarMonitor.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
            }
        }
    }

    private var obsidianStep: some View {
        OnboardingStepLayout(
            title: "Keep a daily work log in Obsidian",
            detail: "This optional export turns BreakBar’s local history into a section "
                + "of each day’s Markdown note."
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        LabeledContent(
                            "Daily notes folder",
                            value: model.obsidianFolderDisplayName
                        )
                        Spacer()
                        Button(
                            "Choose Folder",
                            action: model.chooseObsidianDailyNotesFolder
                        )
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What happens")
                            .font(.headline)

                        Text(
                            "1. Setup saves this folder location; it does not export "
                                + "anything yet."
                        )
                        Text(
                            "2. After clock-out or a history correction, BreakBar creates "
                                + "or updates " + model.obsidianFilenameExample + " with a work "
                                + "summary and interval timeline."
                        )
                        Text(
                            "3. Only BreakBar’s marked section is replaced, so everything "
                                + "else in the note stays untouched."
                        )
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            Text("You can change the note path or export manually later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var optionsStep: some View {
        OnboardingStepLayout(
            title: "Choose the helpers you want",
            detail: "These choices are independent, and none of them can take control of the timer."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live meetings")
                            .font(.headline)

                        LabeledContent(
                            "Detection",
                            value: model.callActivityMonitor.status.description
                        )
                        Toggle(
                            "Treat browser microphone use as a meeting",
                            isOn: Binding(
                                get: { model.allowUncorrelatedBrowserCalls },
                                set: model.setAllowUncorrelatedBrowserCalls
                            )
                        )
                        Text(
                            "BreakBar checks whether a recognized app is using microphone input. "
                                + "It never records or listens to audio."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Startup")
                            .font(.headline)

                        Toggle(
                            "Launch BreakBar at login",
                            isOn: Binding(
                                get: { model.launchAtLoginRequested },
                                set: model.setLaunchAtLogin
                            )
                        )

                        if let message = model.launchAtLoginMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private var readyStep: some View {
        OnboardingStepLayout(
            title: "Ready when you are",
            detail: "BreakBar stays clocked out until you choose Clock In from the menu bar. "
                + "Setup can be run again from Settings at any time."
        ) {
            GroupBox {
                VStack(spacing: 0) {
                    OnboardingSummaryRow(
                        symbol: "bell.badge",
                        title: "Notifications",
                        value: notificationDescription
                    )
                    Divider()
                    OnboardingSummaryRow(
                        symbol: "calendar",
                        title: "Calendar",
                        value: model.calendarMonitor.accessState.description
                    )
                    Divider()
                    OnboardingSummaryRow(
                        symbol: "doc.text",
                        title: "Obsidian",
                        value: model.obsidianFolderDisplayName
                    )
                    Divider()
                    OnboardingSummaryRow(
                        symbol: "power",
                        title: "Launch at login",
                        value: model.launchAtLoginRequested ? "On" : "Off"
                    )
                }
                .padding(.horizontal, 8)
            }

            Label(
                "No timer has started yet.",
                systemImage: "pause.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Set Up Later", action: finish)
                .buttonStyle(.plain)

            Spacer()

            Button("Back") {
                progress.moveBack()
            }
            .disabled(!progress.canMoveBack)

            Button(progress.isFinalStep ? "Finish" : "Continue") {
                if progress.isFinalStep {
                    finish()
                } else {
                    progress.moveForward()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var notificationDescription: String {
        switch model.notificationAccessState {
        case .notDetermined: "Not requested"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .unknown: "Status unavailable"
        }
    }

    private var notificationSymbol: String {
        switch model.notificationAccessState {
        case .enabled: "checkmark.circle.fill"
        case .disabled: "exclamationmark.triangle.fill"
        case .notDetermined, .unknown: "bell.badge.fill"
        }
    }

    private var notificationColor: Color {
        switch model.notificationAccessState {
        case .enabled: .green
        case .disabled: .orange
        case .notDetermined, .unknown: .accentColor
        }
    }
}

private struct BreakLoopDiagram: View {
    var body: some View {
        HStack(spacing: 10) {
            LoopStage(symbol: "timer", title: "Focus", detail: "55 min")
            loopArrow
            LoopStage(symbol: "bell.badge", title: "Warning", detail: "5 min")
            loopArrow
            LoopStage(symbol: "figure.walk.motion", title: "Break", detail: "5+ min")
            loopArrow
            LoopStage(symbol: "arrow.counterclockwise", title: "Return", detail: "Fresh timer")
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Focus for 55 minutes, receive a 5 minute warning, take a break for at least "
                + "5 minutes, then return to a fresh timer"
        )
    }

    private var loopArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct LoopStage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingStepLayout<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingSummaryRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}
