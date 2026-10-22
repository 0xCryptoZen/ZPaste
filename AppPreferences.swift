import Foundation
import Combine

extension Notification.Name {
    static let historyPolicyChanged = Notification.Name("ZPaste.HistoryPolicyChanged")
}

enum AppPreferences {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "pasteOnClick": true,
            "retentionDays": 0,
            "historyLimit": 0,
            "capturePaused": false,
            "mergeDuplicates": true,
            "ignoreConfidential": true,
            "ignoreTransient": true,
            "hotKeyCode": 9,
            "hotKeyModifiers": 768, // Command + Shift (Carbon flags)
            "ignoredBundleIDs": [
                "com.1password.1password", "com.agilebits.onepassword7",
                "com.apple.keychainaccess", "com.bitwarden.desktop"
            ]
        ])
    }
}

@MainActor
final class AppStatus: ObservableObject {
    static let shared = AppStatus()
    @Published var errorMessage: String?
    @Published private(set) var feedback: String?
    private var feedbackTask: Task<Void, Never>?

    func copied() { showFeedback("Copied to clipboard") }

    func previewed() { showFeedback("Preview only · Clipboard unchanged") }

    private func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        feedback = message
        feedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            feedback = nil
        }
    }
}
