import AppKit
import Foundation

@MainActor
enum MediaPlaybackController {
    private struct Player {
        let name: String
        let bundleIdentifier: String
    }

    private static let supportedPlayers = [
        Player(name: "Apple Music", bundleIdentifier: "com.apple.Music"),
        Player(name: "Spotify", bundleIdentifier: "com.spotify.client"),
    ]

    static func pauseRunningPlayers() -> String? {
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let runningPlayers = supportedPlayers.filter {
            runningBundleIdentifiers.contains($0.bundleIdentifier)
        }
        let failures = runningPlayers.compactMap(pause)
        guard !failures.isEmpty else { return nil }
        return "Break started, but \(failures.joined(separator: "; "))."
    }

    private static func pause(_ player: Player) -> String? {
        let source = "tell application id \"\(player.bundleIdentifier)\" to pause"
        guard let script = NSAppleScript(source: source) else {
            return "\(player.name) could not be controlled"
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let detail = error[NSAppleScript.errorMessage] as? String
            ?? "macOS denied media control"
        return "\(player.name) was not paused: \(detail)"
    }
}
