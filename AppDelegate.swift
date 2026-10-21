import AppKit
import SwiftUI

extension Notification.Name {
    static let showHistoryWindow = Notification.Name("ZPaste.ShowHistoryWindow")
}

/// Starts clipboard monitoring, registers the global hotkey, and hosts the history window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: ClipboardMonitor?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Pure menu-bar app (no Dock icon).
            NSApp.setActivationPolicy(.accessory)

            let monitor = ClipboardMonitor(modelContext: Store.container.mainContext)
            self.monitor = monitor
            monitor.start()
        }

        // Global hotkey ⌘⇧V.
        HotKeyManager.shared.registerDefault()

        NotificationCenter.default.addObserver(
            forName: .quickPasteHotKey, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showHistory() }
        }

        NotificationCenter.default.addObserver(
            forName: .showHistoryWindow, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showHistory() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.monitor?.stop()
        }
        HotKeyManager.shared.unregister()
    }

    @MainActor
    private func showHistory() {
        if historyWindow == nil {
            let root = HistoryView().modelContainer(Store.container)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 520))
            window.center()
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }
}