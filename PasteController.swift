import AppKit
import ApplicationServices

/// Tracks the destination independently of a clip's source application.
@MainActor
final class PasteController: ObservableObject {
    static let shared = PasteController()
    @Published private(set) var targetName = "previous app"
    private var target: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var delivery: Task<Void, Never>?

    func start() {
        rememberFrontmostApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }

    func stop() {
        delivery?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    func rememberFrontmostApplication() {
        if let app = NSWorkspace.shared.frontmostApplication { remember(app) }
    }

    private func remember(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated else { return }
        target = app
        targetName = app.localizedName ?? "previous app"
    }

    func copy(_ text: String) {
        delivery?.cancel()
        if ClipboardMonitor.write(text) { AppStatus.shared.copied() }
        else { showError("Could not write to the clipboard.") }
    }

    func select(_ text: String, forcePaste: Bool = false) {
        delivery?.cancel()
        guard ClipboardMonitor.write(text) else {
            showError("Could not write to the clipboard.")
            return
        }
        guard forcePaste || UserDefaults.standard.bool(forKey: "pasteOnClick") else {
            AppStatus.shared.copied()
            return
        }
        guard AXIsProcessTrusted() else {
            let alert = NSAlert()
            alert.messageText = "Allow ZPaste to paste"
            alert.informativeText = "The text has been copied. Enable ZPaste in System Settings → Privacy & Security → Accessibility, then try again. You can also paste manually with ⌘V."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Copy Only")
            if alert.runModal() == .alertFirstButtonReturn { Self.openAccessibilitySettings() }
            return
        }
        guard let target, !target.isTerminated else {
            showError("The text has been copied. Click the destination input field, reopen ZPaste, and choose the item again.")
            return
        }
        let changeCount = NSPasteboard.general.changeCount
        NSApp.hide(nil)
        guard target.activate(options: []) else {
            showError("Could not activate the destination app. The text is copied; paste it manually with ⌘V.")
            return
        }
        delivery = Task { @MainActor in
            // Activation is asynchronous. Wait for the real destination, then let its field regain focus.
            for _ in 0..<40 {
                guard !Task.isCancelled, !target.isTerminated else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard PasteDeliveryPolicy.canSend(
                targetPID: target.processIdentifier,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                targetTerminated: target.isTerminated,
                clipboardUnchanged: NSPasteboard.general.changeCount == changeCount,
                cancelled: Task.isCancelled
            ) else {
                if !Task.isCancelled { self.showError("The destination or clipboard changed. Paste was cancelled; select the input field and try again.") }
                return
            }
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                self.showError("Could not create a paste event. The text is copied; paste manually with ⌘V.")
                return
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(target.processIdentifier)
            up.postToPid(target.processIdentifier)
        }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func showError(_ message: String) {
        AppStatus.shared.errorMessage = message
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ZPaste"
        alert.informativeText = message
        alert.runModal()
    }
}
