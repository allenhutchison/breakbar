import BreakBarCore
import SwiftUI

struct BreakBarMenuView: View {
    @ObservedObject var model: AppModel

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

                if model.state.phase != .clockedOut {
                    Button("Clock out", action: model.clockOut)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Label("Mac timer", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Settings")
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

private struct TimerInstrument: View {
    let progress: Double
    let label: String
    let timer: BreakBarTimerPresentation?
    let palette: BreakPalette

    var body: some View {
        ZStack {
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
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
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
        case .warning:
            accent = Color(red: 0.96, green: 0.61, blue: 0.08)
        case .required:
            accent = Color(red: 0.91, green: 0.20, blue: 0.23)
        case .breakTime:
            accent = Color(red: 0.12, green: 0.64, blue: 0.48)
        }
        track = accent.opacity(0.16)
    }
}
