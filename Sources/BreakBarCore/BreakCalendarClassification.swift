import Foundation

public enum BreakCalendarClassifier {
    public static func classify(
        title: String,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        calendarTitle: String? = nil
    ) -> BreakCalendarConstraintKind {
        let titleText = normalized(title)
        let allText = normalized(
            [title, location, notes, url?.absoluteString, calendarTitle]
                .compactMap { $0 }
                .joined(separator: " ")
        )

        if containsPhrase(in: titleText, phrases: ["travel", "commute", "drive"]) {
            return .travel
        }
        if containsPhrase(in: titleText, phrases: ["lunch"]) {
            return .lunch
        }
        if containsPhrase(
            in: allText,
            phrases: ["offsite", "off-site", "onsite", "on-site", "in person", "in-person"]
        ) {
            return .offsiteMeeting
        }

        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let virtualMarkers = [
                "zoom", "meet.google", "teams.microsoft", "webex", "facetime",
                "video call", "online", "virtual"
            ]
            if !virtualMarkers.contains(where: { normalized(location).contains($0) }) {
                return .offsiteMeeting
            }
        }
        return .meeting
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsPhrase(in text: String, phrases: [String]) -> Bool {
        phrases.contains { phrase in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
        }
    }
}
