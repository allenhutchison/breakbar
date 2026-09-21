import BreakBarCore
import EventKit
import Foundation

enum CalendarAccessState: Equatable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
    case unknown

    var description: String {
        switch self {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .writeOnly: "Write-only access"
        case .fullAccess: "Connected"
        case .unknown: "Unknown"
        }
    }
}

struct BreakBarCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
}

struct UpcomingCalendarEvent: Equatable {
    let id: String
    let title: String
    let calendarTitle: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

@MainActor
final class CalendarMonitor: NSObject, ObservableObject {
    @Published private(set) var accessState: CalendarAccessState = .notDetermined
    @Published private(set) var calendars: [BreakBarCalendar] = []
    @Published private(set) var selectedCalendarIDs: Set<String> = []
    @Published private(set) var nextEvent: UpcomingCalendarEvent?
    @Published private(set) var schedulingConstraints: [BreakCalendarConstraint] = []
    @Published private(set) var message: String?

    private static let selectionKey = "calendar.selectedIdentifiers"
    private let eventStore = EKEventStore()
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        monitoringEnabled: Bool = true
    ) {
        self.defaults = defaults
        super.init()

        guard monitoringEnabled else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged(_:)),
            name: .EKEventStoreChanged,
            object: eventStore
        )
        refresh()
        startRefreshTask()
    }

    deinit {
        refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func requestAccess() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await eventStore.requestFullAccessToEvents()
                message = nil
            } catch {
                message = "Calendar access failed: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    func setCalendar(_ id: String, included: Bool) {
        if included {
            selectedCalendarIDs.insert(id)
        } else {
            selectedCalendarIDs.remove(id)
        }
        defaults.set(Array(selectedCalendarIDs).sorted(), forKey: Self.selectionKey)
        refreshEvents()
    }

    func isCalendarSelected(_ id: String) -> Bool {
        selectedCalendarIDs.contains(id)
    }

    func refresh() {
        accessState = Self.currentAccessState()
        guard accessState == .fullAccess else {
            calendars = []
            nextEvent = nil
            schedulingConstraints = []
            return
        }

        let eventCalendars = eventStore.calendars(for: .event)
        calendars = eventCalendars
            .map {
                BreakBarCalendar(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                if $0.sourceTitle == $1.sourceTitle { return $0.title < $1.title }
                return $0.sourceTitle < $1.sourceTitle
            }

        let availableIDs = Set(calendars.map(\.id))
        if let stored = defaults.array(forKey: Self.selectionKey) as? [String] {
            selectedCalendarIDs = Set(stored).intersection(availableIDs)
        } else {
            selectedCalendarIDs = availableIDs
            defaults.set(Array(availableIDs).sorted(), forKey: Self.selectionKey)
        }
        refreshEvents(using: eventCalendars)
    }

    private func refreshEvents(using calendars: [EKCalendar]? = nil) {
        guard accessState == .fullAccess, !selectedCalendarIDs.isEmpty else {
            nextEvent = nil
            schedulingConstraints = []
            return
        }

        let includedCalendars = (calendars ?? eventStore.calendars(for: .event))
            .filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-24 * 60 * 60),
            end: now.addingTimeInterval(7 * 24 * 60 * 60),
            calendars: includedCalendars
        )
        let events = eventStore.events(matching: predicate)
            .filter { $0.status != .canceled && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }

        nextEvent = events.first
            .map {
                let title = ($0.title?.isEmpty == false ? $0.title : nil) ?? "Untitled event"
                return UpcomingCalendarEvent(
                    id: $0.calendarItemIdentifier,
                    title: title,
                    calendarTitle: $0.calendar.title,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay
                )
            }
        schedulingConstraints = events
            .filter { !$0.isAllDay && $0.endDate > $0.startDate }
            .map {
                BreakCalendarConstraint(
                    id: $0.eventIdentifier
                        ?? "\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSinceReferenceDate)",
                    startAt: $0.startDate,
                    endAt: $0.endDate,
                    kind: BreakCalendarClassifier.classify(
                        title: $0.title ?? "",
                        location: $0.structuredLocation?.title ?? $0.location,
                        notes: $0.notes,
                        url: $0.url,
                        calendarTitle: $0.calendar.title
                    )
                )
            }
    }

    private func startRefreshTask() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refreshEvents()
            }
        }
    }

    @objc private func eventStoreChanged(_ notification: Notification) {
        refresh()
    }

    private static func currentAccessState() -> CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess, .authorized: .fullAccess
        @unknown default: .unknown
        }
    }
}
