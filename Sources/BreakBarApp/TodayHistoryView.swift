import BreakBarPersistence
import SwiftUI

struct TodayHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var historyEditor: HistoryEditor?

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

                if !history.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Work sessions")
                            .font(.title3.weight(.semibold))

                        VStack(spacing: 0) {
                            ForEach(Array(history.sessions.enumerated()), id: \.element.id) { index, session in
                                Button {
                                    historyEditor = .session(session)
                                } label: {
                                    SessionRow(
                                        title: sessionTitle(index: index, count: history.sessions.count),
                                        session: session,
                                        history: history,
                                        now: model.now,
                                        showsEditIndicator: true
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(
                                    session.endedAt == nil
                                        ? "Edit the clock-in time"
                                        : "Edit clock-in and clock-out times"
                                )
                                if index < history.sessions.count - 1 {
                                    Divider().padding(.leading, 42)
                                }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    }
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
                                if interval.endedAt == nil {
                                    TimelineRow(
                                        interval: interval,
                                        history: history,
                                        now: model.now,
                                        showsEditIndicator: false
                                    )
                                } else {
                                    Button {
                                        historyEditor = .interval(interval)
                                    } label: {
                                        TimelineRow(
                                            interval: interval,
                                            history: history,
                                            now: model.now,
                                            showsEditIndicator: true
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Edit this activity")
                                }
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
        .sheet(item: $historyEditor) { editor in
            switch editor {
            case let .interval(interval):
                HistoryCorrectionView(model: model, interval: interval)
            case let .session(session):
                SessionCorrectionView(model: model, session: session)
            }
        }
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

    private func sessionTitle(index: Int, count: Int) -> String {
        count == 1 ? "Work session" : "Work session \(index + 1)"
    }
}

private enum HistoryEditor: Identifiable {
    case interval(ActivityHistoryInterval)
    case session(WorkSessionHistory)

    var id: String {
        switch self {
        case let .interval(interval): "interval-\(interval.id)"
        case let .session(session): "session-\(session.id)"
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

private struct SessionRow: View {
    let title: String
    let session: WorkSessionHistory
    let history: DailyHistory
    let now: Date
    let showsEditIndicator: Bool

    var body: some View {
        let start = max(history.day.start, session.startedAt)
        let end = min(history.day.end, session.endedAt ?? now)

        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.primary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if session.endedAt == nil {
                        Text("NOW")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                    }
                    if session.wasCorrected {
                        Text("EDITED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(DurationText.compact(end.timeIntervalSince(start)))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(minWidth: 58, alignment: .trailing)

            if showsEditIndicator {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var timeRange: String {
        let startText = session.startedAt.formatted(date: .omitted, time: .shortened)
        let endText = session.endedAt?.formatted(date: .omitted, time: .shortened) ?? "Now"
        return "\(startText) – \(endText)"
    }

    private var accessibilityDescription: String {
        let start = max(history.day.start, session.startedAt)
        let end = min(history.day.end, session.endedAt ?? now)
        var components = [title]
        if session.endedAt == nil {
            components.append("active")
        }
        if session.wasCorrected {
            components.append("edited")
        }
        components.append(timeRange)
        components.append(DurationText.spoken(end.timeIntervalSince(start)))
        return components.joined(separator: ", ")
    }
}

private struct TimelineRow: View {
    let interval: ActivityHistoryInterval
    let history: DailyHistory
    let now: Date
    let showsEditIndicator: Bool

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
                    if interval.wasCorrected {
                        Text("EDITED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
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

            if showsEditIndicator {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
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

private struct SessionCorrectionView: View {
    @ObservedObject var model: AppModel
    let session: WorkSessionHistory

    @Environment(\.dismiss) private var dismiss
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var errorMessage: String?

    init(model: AppModel, session: WorkSessionHistory) {
        self.model = model
        self.session = session
        _startedAt = State(initialValue: session.startedAt)
        _endedAt = State(initialValue: session.endedAt ?? session.startedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit work session")
                    .font(.title2.weight(.semibold))
                Text(
                    isActive
                        ? "Update when this active work session began."
                        : "The first and last activity will be adjusted to match these times."
                )
                    .foregroundStyle(.secondary)
            }

            Form {
                DatePicker(
                    "Clocked in",
                    selection: $startedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                if isActive {
                    LabeledContent("Clocked out", value: "Now")
                } else {
                    DatePicker(
                        "Clocked out",
                        selection: $endedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isActive ? startedAt >= model.now : startedAt >= endedAt)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        do {
            if isActive {
                try model.correctActiveWorkSessionClockIn(session, startedAt: startedAt)
            } else {
                try model.correctWorkSession(
                    session,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var isActive: Bool { session.endedAt == nil }
}

private struct HistoryCorrectionView: View {
    @ObservedObject var model: AppModel
    let interval: ActivityHistoryInterval

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ActivityKind
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var errorMessage: String?

    init(model: AppModel, interval: ActivityHistoryInterval) {
        self.model = model
        self.interval = interval
        _kind = State(initialValue: interval.kind)
        _startedAt = State(initialValue: interval.startedAt)
        _endedAt = State(initialValue: interval.endedAt ?? interval.startedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit activity")
                    .font(.title2.weight(.semibold))
                Text("Update the category or timing for this completed interval.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Category", selection: $kind) {
                    ForEach(ActivityKind.allCases, id: \.self) { activityKind in
                        Label(activityKind.title, systemImage: activityKind.symbolName)
                            .tag(activityKind)
                    }
                }

                DatePicker(
                    "Start",
                    selection: $startedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                DatePicker(
                    "End",
                    selection: $endedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(startedAt >= endedAt)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        do {
            try model.correctHistoryInterval(
                interval,
                kind: kind,
                startedAt: startedAt,
                endedAt: endedAt
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
