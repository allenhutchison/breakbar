import AppKit
@preconcurrency import UserNotifications

@MainActor
enum WarningNotifier {
    static func deliver(remaining: TimeInterval, revision: UInt64) {
        playSound()

        let content = UNMutableNotificationContent()
        content.title = "Break in \(durationText(remaining))"
        content.body = "Find a stopping point."

        let request = UNNotificationRequest(
            identifier: "break-warning-\(revision)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("BreakBar could not deliver its warning notification: %@", error.localizedDescription)
            }
        }
    }

    private static func playSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        if seconds >= 60 && seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
