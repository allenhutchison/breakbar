import BreakBarCore
import SwiftUI

struct BreakBarMenuView: View {
    @ObservedObject var model: AppModel
    let checkForUpdates: () -> Void
    let showSettings: () -> Void

    private var palette: BreakPalette {
        BreakPalette(tone: model.presentation.tone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                TimerInstrument(
                    progress: model.presentation.progress,
                    label: model.presentation.shortLabel,
                    timer: model.presentation.timer,
                    palette: palette
                )

                VStack(alignment: .leading, spacing: 7) {
                    if model.isDemoMode {
                        Text("DEMO CYCLE")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(palette.accent)
                    }

                    Text(model.presentation.title)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(model.presentation.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)

            Divider()

            CalendarMenuSummary(monitor: model.calendarMonitor)

            Divider()

            if let message = model.lastMessage {
                Label(message, systemImage: "hourglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .onTapGesture { model.clearMessage() }
            }

            VStack(spacing: 10) {
                if let title = model.presentation.primaryActionTitle {
                    Button(action: model.performPrimaryAction) {
                        Text(title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .controlSize(.large)
                }

                if model.state.phase == .focusing,
                   model.state.manualMeetingStartedAt == nil
                {
                    Button(action: model.startLunch) {
                        Text("Take lunch")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BreakPalette(tone: .lunch).accent)
                    .controlSize(.large)

                    if model.presentation.tone != .meeting {
                        Button(action: model.startManualMeeting) {
                            Text("In a meeting")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BreakPalette(tone: .meeting).accent)
                        .controlSize(.large)
                    }
                }

                if model.state.phase == .awayUnclassified,
                   model.state.awayReturnDetectedAt != nil
                {
                    AwayClassificationButtons(model: model)
                }

                if model.state.phase != .clockedOut {
                    Button(action: model.clockOut) {
                        Text("Clock out")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BreakPalette(tone: .neutral).accent)
                    .controlSize(.large)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Label("Mac timer", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.showTodayHistory()
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.plain)
                .help("Today’s history")
                Button(action: checkForUpdates) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .help("Check for Updates…")
                .accessibilityLabel("Check for Updates")
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Settings")
                Button(action: model.quit) {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Quit BreakBar")
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }
}

private struct AwayClassificationButtons: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text("Classify your time away")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            classificationButton(
                model.preferredAwayClassification == .lunch ? "Lunch · Suggested" : "Lunch",
                tone: .lunch,
                classification: .lunch
            )
            classificationButton("Break", tone: .breakTime, classification: .breakTime)
            classificationButton("Other away", tone: .away, classification: .otherAway)
            classificationButton("Count as work", tone: .focus, classification: .countAsWork)
        }
    }

    private func classificationButton(
        _ title: String,
        tone: BreakBarPresentation.Tone,
        classification: AwayClassification
    ) -> some View {
        Button {
            model.classifyAway(as: classification)
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(BreakPalette(tone: tone).accent)
        .controlSize(.large)
    }
}

private struct CalendarMenuSummary: View {
    @ObservedObject var monitor: CalendarMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            if let event = monitor.nextEvent {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(eventTiming(event))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(calendarStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var calendarStatusText: String {
        switch monitor.accessState {
        case .fullAccess: "No upcoming selected events"
        case .notDetermined: "Calendar not connected"
        case .denied, .restricted, .writeOnly: "Calendar access unavailable"
        case .unknown: "Calendar status unavailable"
        }
    }

    private func eventTiming(_ event: UpcomingCalendarEvent) -> String {
        if event.isAllDay { return "All day · \(event.calendarTitle)" }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(formatter.string(from: event.startDate, to: event.endDate)) · \(event.calendarTitle)"
    }
}

private struct TimerInstrument: View {
    let progress: Double
    let label: String
    let timer: BreakBarTimerPresentation?
    let palette: BreakPalette

    var body: some View {
        ZStack {
            if timer == nil, label == "BreakBar" {
                IdleBrandMark()
            } else {
                Circle()
                    .stroke(palette.track, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.012, progress))
                    .stroke(
                        palette.accent,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                if let timer {
                    StableTimerText(
                        text: timer.text,
                        fontSize: 17,
                        weight: .bold,
                        width: 68,
                        alignment: .center
                    )
                } else {
                    Text(label)
                        .font(.system(size: label.count > 7 ? 13 : 17, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                        .frame(width: 68, alignment: .center)
                }
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct IdleBrandMark: View {
    private let brandOrange = Color(red: 1, green: 0.54, blue: 0.16)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.16, blue: 0.22),
                            Color(red: 0.05, green: 0.07, blue: 0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.20), radius: 5, y: 3)

            Circle()
                .trim(from: 0.06, to: 0.94)
                .stroke(
                    brandOrange,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-30))
                .padding(12)

            Capsule()
                .fill(.white)
                .frame(width: 4, height: 25)
                .offset(y: -10)

            Capsule()
                .fill(.white)
                .frame(width: 4, height: 22)
                .offset(y: -8)
                .rotationEffect(.degrees(125))

            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
        }
        .padding(2)
    }
}

struct BreakPalette {
    let accent: Color
    let track: Color

    init(tone: BreakBarPresentation.Tone) {
        switch tone {
        case .neutral:
            accent = Color(nsColor: .systemGray)
        case .focus:
            accent = Color(red: 0.16, green: 0.47, blue: 0.88)
        case .meeting:
            accent = Color(red: 0.48, green: 0.35, blue: 0.82)
        case .warning:
            accent = Color(red: 0.96, green: 0.61, blue: 0.08)
        case .required:
            accent = Color(red: 0.91, green: 0.20, blue: 0.23)
        case .breakTime:
            accent = Color(red: 0.12, green: 0.64, blue: 0.48)
        case .lunch:
            accent = Color(red: 0.90, green: 0.45, blue: 0.16)
        case .away:
            accent = Color(red: 0.42, green: 0.44, blue: 0.50)
        case .travel:
            accent = Color(red: 0.94, green: 0.48, blue: 0.12)
        }
        track = accent.opacity(0.16)
    }
}
