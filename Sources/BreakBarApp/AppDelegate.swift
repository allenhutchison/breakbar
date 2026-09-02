import AppKit
import Combine
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    private let compactStatusItemWidth: CGFloat = 62
    private let longTimerStatusItemWidth: CGFloat = 70
    private let expandedStatusItemWidth: CGFloat = 86
    private let travelWarningStatusItemWidth: CGFloat = 104
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var modelObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()
        observeModel()
        observeLifecycleChanges()
        updateStatusItem()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("BreakBar could not request notification permission: %@", error.localizedDescription)
            } else if !granted {
                NSLog("BreakBar notifications are disabled; warning sounds will still play.")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLaunchAtLoginStatus()
        model.calendarMonitor.refresh()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: compactStatusItemWidth)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "BreakBar"
        statusItem = item
    }

    private func configurePopover() {
        let content = BreakBarMenuView(model: model)
            .fixedSize(horizontal: false, vertical: true)
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.layoutSubtreeIfNeeded()

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(
            width: 360,
            height: hostingController.view.fittingSize.height
        )
    }

    private func observeModel() {
        modelObservation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
    }

    private func observeLifecycleChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reconcileAfterLifecycleChange(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reconcileAfterLifecycleChange(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reconcileAfterLifecycleChange(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(reconcileAfterLifecycleChange(_:)),
            name: Notification.Name("com.apple.screensaver.didstop"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconcileAfterLifecycleChange(_:)),
            name: .NSSystemClockDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconcileAfterLifecycleChange(_:)),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    @objc private func reconcileAfterLifecycleChange(_ notification: Notification) {
        model.reconcileAfterLifecycleEvent()
        model.calendarMonitor.refresh()
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        let presentation = model.presentation
        let itemWidth: CGFloat
        if presentation.statusLabel == "Leave " {
            itemWidth = travelWarningStatusItemWidth
        } else if presentation.timer == nil && presentation.statusLabel == "BreakBar" {
            itemWidth = expandedStatusItemWidth
        } else if presentation.shortLabel.count > 5 {
            itemWidth = longTimerStatusItemWidth
        } else {
            itemWidth = compactStatusItemWidth
        }
        if statusItem.length != itemWidth {
            statusItem.length = itemWidth
        }
        button.image = statusImage(
            symbolName: model.menuBarSymbol,
            text: presentation.shortLabel,
            width: itemWidth
        )
        button.toolTip = "BreakBar — \(presentation.shortLabel)"
        button.setAccessibilityLabel("BreakBar, \(presentation.shortLabel)")
    }

    private func statusImage(symbolName: String, text: String, width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { bounds in
            NSGraphicsContext.current?.imageInterpolation = .high

            if let symbol = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ) {
                let symbolSize = NSSize(width: 15, height: 15)
                symbol.draw(in: NSRect(
                    x: 1,
                    y: floor((bounds.height - symbolSize.height) / 2),
                    width: symbolSize.width,
                    height: symbolSize.height
                ))
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
            let string = text as NSString
            let measured = string.size(withAttributes: attributes)
            string.draw(
                in: NSRect(
                    x: 20,
                    y: floor((bounds.height - measured.height) / 2),
                    width: bounds.width - 21,
                    height: ceil(measured.height)
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
