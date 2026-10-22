import AppKit
import SwiftUI

extension Notification.Name {
    static let showHistoryWindow = Notification.Name("ZPaste.ShowHistoryWindow")
    static let showSettingsWindow = Notification.Name("ZPaste.ShowSettingsWindow")
}

/// Starts clipboard monitoring, registers the global hotkey, and hosts the history window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: ClipboardMonitor?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            if UIPreviewData.enabled {
                do { try UIPreviewData.populate(Store.container.mainContext) }
                catch { AppStatus.shared.errorMessage = error.localizedDescription }
                showHistory()
            } else {
                PasteController.shared.start()
                let monitor = ClipboardMonitor(modelContext: Store.container.mainContext)
                self.monitor = monitor
                monitor.start()
                do { try HotKeyManager.shared.registerSaved() }
                catch { AppStatus.shared.errorMessage = error.localizedDescription }
            }
        }

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
        NotificationCenter.default.addObserver(
            forName: .showSettingsWindow, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.monitor?.stop()
            PasteController.shared.stop()
            HotKeyManager.shared.unregister()
        }
    }

    @MainActor
    private func showHistory() {
        PasteController.shared.rememberFrontmostApplication()
        if historyWindow == nil {
            let root = HistoryView().modelContainer(Store.container)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "ZPaste"
            window.toolbarStyle = .unified
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 640))
            window.minSize = NSSize(width: 800, height: 540)
            window.setFrameAutosaveName("ZPaste.HistoryWindow")
            if !window.setFrameUsingName("ZPaste.HistoryWindow") { window.center() }
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView { [weak self] in self?.settingsWindow?.performClose(nil) }
                .modelContainer(Store.container)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "ZPaste Settings"
            window.toolbarStyle = .unified
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 620))
            window.minSize = NSSize(width: 760, height: 560)
            window.setFrameAutosaveName("ZPaste.SettingsWindow")
            if !window.setFrameUsingName("ZPaste.SettingsWindow") { window.center() }
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
