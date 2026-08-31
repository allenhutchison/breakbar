import BreakBarCore
import Foundation

/// Read-only bridge for installations that ran before the SQLite ledger existed.
/// The legacy file is intentionally retained as a recovery artifact.
enum LegacyStatePersistence {
    private static var stateURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("BreakBar", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func load() -> BreakBarState? {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(BreakBarState.self, from: data)
    }
}
