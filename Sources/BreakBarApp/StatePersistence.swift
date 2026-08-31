import BreakBarCore
import Foundation

enum StatePersistence {
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

    static func save(_ state: BreakBarState) {
        guard let url = stateURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("BreakBar could not save state: %@", error.localizedDescription)
        }
    }
}
