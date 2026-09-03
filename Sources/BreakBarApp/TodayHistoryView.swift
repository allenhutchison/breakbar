import BreakBarPersistence
import SwiftUI

struct TodayHistoryView: View {
    @ObservedObject var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        Group {
            if let history = model.todayHistory {
                historyContent(history)
            } else if let message = model.historyMessage {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else {
                ProgressView("Loading today’s history…")
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: model.refreshTodayHistory)
    }

    private func historyContent(_ history: DailyHistory) -> some View {
        let summary = history.summary(at: model.now)

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(history)

                LazyVGrid(columns: columns, spacing: 10) {
                    SummaryCard(title: "Clocked in", duration: summary.clockedIn, color: .primary)
                    SummaryCard(title: "Working", duration: summary.working, color: .blue)
                    SummaryCard(title: "Focus", duration: summary.focus, color: .blue)
                    SummaryCard(title: "Meetings", duration: summary.meetings, color: .purple)
                    SummaryCard(title: "Breaks", duration: summary.breaks, color: .green)
                    SummaryCard(title: "Lunch", duration: summary.lunch, color: .orange)
                    SummaryCard(title: "Travel", duration: summary.travel, color: .orange)
                    SummaryCard(title: "Away", duration: summary.away, color: .gray)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Timeline")
                        .font(.title3.weight(.semibold))

                    if history.intervals.isEmpty {
                        ContentUnavailableView(
                            "No activity yet",
                            systemImage: "clock",
                            description: Text("Clock in to begin today’s timeline.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(history.intervals.enumerated()), id: \.element.id) { index, interval in
                                TimelineRow(
                                    interval: interval,
                                    history: history,
                                    now: model.now
                                )
                                if index < history.intervals.count - 1 {
                                    Divider().padding(.leading, 42)
                                }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ history: DailyHistory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Today")
                    .font(.largeTitle.weight(.bold))
                Text(history.day.start.formatted(date: .complete, time: .omitted))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refreshTodayHistory()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let duration: TimeInterval
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(DurationText.compact(duration))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(DurationText.spoken(duration))")
    }
}

private struct TimelineRow: View {
    let interval: ActivityHistoryInterval
    let history: DailyHistory
    let now: Date

    var body: some View {
        let start = history.clippedStart(for: interval)
        let end = history.clippedEnd(for: interval, at: now)

        HStack(spacing: 12) {
            Image(systemName: interval.kind.symbolName)
                .foregroundStyle(interval.kind.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(interval.kind.title)
                        .font(.body.weight(.medium))
                    if interval.endedAt == nil {
                        Text("NOW")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(interval.kind.color)
                    }
                }
                Text(timeRange(from: start, to: end))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(DurationText.compact(end.timeIntervalSince(start)))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(interval.kind.title), \(timeRange(from: start, to: end)), \(DurationText.spoken(end.timeIntervalSince(start)))"
        )
    }

    private func timeRange(from start: Date, to end: Date) -> String {
        let startText = start.formatted(date: .omitted, time: .shortened)
        let endText = interval.endedAt == nil
            ? "Now"
            : end.formatted(date: .omitted, time: .shortened)
        return "\(startText) – \(endText)"
    }
}

private enum DurationText {
    static func compact(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration) / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    static func spoken(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration) / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) minutes" }
        if remainder == 0 { return "\(hours) hours" }
        return "\(hours) hours, \(remainder) minutes"
    }
}

private extension ActivityKind {
    var title: String {
        switch self {
        case .focus: "Focus"
        case .meeting: "Meeting"
        case .breakTime: "Break"
        case .lunch: "Lunch"
        case .travel: "Travel"
        case .away: "Away"
        }
    }

    var symbolName: String {
        switch self {
        case .focus: "timer"
        case .meeting: "video.fill"
        case .breakTime: "cup.and.heat.waves.fill"
        case .lunch: "fork.knife"
        case .travel: "car.fill"
        case .away: "figure.walk"
        }
    }

    var color: Color {
        switch self {
        case .focus: .blue
        case .meeting: .purple
        case .breakTime: .green
        case .lunch, .travel: .orange
        case .away: .gray
        }
    }
}
