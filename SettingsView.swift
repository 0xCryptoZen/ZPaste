import AppKit
import ApplicationServices
import ServiceManagement
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "General", privacy = "Privacy", keyboard = "Keyboard Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .privacy: return "hand.raised"
            case .keyboard: return "keyboard"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var page: Page? = .general
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()
    @State private var ignoredIDs = UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? []
    @State private var newID = ""
    @State private var errorMessage: String?
    @State private var confirmClear = false
    @AppStorage("pasteOnClick") private var pasteOnClick = true
    @AppStorage("retentionDays") private var retentionDays = 0
    @AppStorage("historyLimit") private var historyLimit = 0
    @AppStorage("capturePaused") private var paused = false
    @AppStorage("mergeDuplicates") private var mergeDuplicates = true
    @AppStorage("ignoreConfidential") private var ignoreConfidential = true
    @AppStorage("ignoreTransient") private var ignoreTransient = true
    @AppStorage("hotKeyDisplay") private var hotKeyDisplay = "⌘⇧V"

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(Page.allCases, selection: $page) { page in
                    Label(page.rawValue, systemImage: page.icon).tag(page)
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            } detail: {
                Form {
                    switch page ?? .general {
                    case .general: general
                    case .privacy: privacy
                    case .keyboard: keyboard
                    }
                }
                .formStyle(.grouped)
                .navigationTitle((page ?? .general).rawValue)
            }
            Divider()
            HStack {
                Text("ZPaste · Text clipboard history").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 800, height: 600)
        .onChange(of: retentionDays) { _, _ in policyChanged() }
        .onChange(of: historyLimit) { _, _ in policyChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("ZPaste", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Clear all unpinned history?", isPresented: $confirmClear) {
            Button("Clear Unpinned History", role: .destructive) {
                do { try HistoryMaintenance.clearUnpinned(in: context) }
                catch { context.rollback(); errorMessage = error.localizedDescription }
            }
        } message: { Text("This cannot be undone. Pinned items and folders will be kept.") }
    }

    private var general: some View {
        Group {
            Section("Startup & Recording") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
                        }
                    }
                Toggle("Pause clipboard recording", isOn: $paused)
                Toggle("Merge duplicate text", isOn: $mergeDuplicates)
                Text("Copying the same text again moves its existing entry to the top and keeps its pin and folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clicking a History Item") {
                Picker("Action", selection: $pasteOnClick) {
                    Text("Paste into the previous app").tag(true)
                    Text("Copy to clipboard only").tag(false)
                }
                Text("Click the destination input field before opening ZPaste. History and menu-bar items use the same action. Text is always copied as plain text.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(trusted ? "Accessibility access enabled" : "Accessibility access needed for direct paste",
                          systemImage: trusted ? "checkmark.circle" : "exclamationmark.circle")
                    Spacer()
                    Button("Open Settings…") { PasteController.openAccessibilitySettings() }
                }
            }
            Section("Keep History") {
                Picker("Retention", selection: $retentionDays) {
                    Text("1 day").tag(1)
                    Text("1 week").tag(7)
                    Text("1 month (30 days)").tag(30)
                    Text("1 year (365 days)").tag(365)
                    Text("Forever").tag(0)
                }
                Picker("Maximum unpinned items", selection: $historyLimit) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1,000").tag(1_000)
                    Text("5,000").tag(5_000)
                    Text("Unlimited").tag(0)
                }
                Text("Pinned items are always kept. Changing these settings immediately removes expired or excess unpinned entries, including items in folders. Cleanup also runs automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Unpinned History…", role: .destructive) { confirmClear = true }
            }
            Section("Sync") {
                Text("iCloud sync is not enabled in the downloadable build. History is stored on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var privacy: some View {
        Group {
            Section("Clipboard Privacy") {
                Toggle("Ignore confidential clipboard items", isOn: $ignoreConfidential)
                Text("Skips items marked as confidential by their source app. This does not detect every password or secret; add sensitive apps to the ignore list below.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Ignore temporary and automatically generated items", isOn: $ignoreTransient)
                Text("Filters future copies only. Existing history is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored Apps") {
                ForEach(ignoredIDs, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                        }
                        Text(id).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            ignoredIDs.removeAll { $0 == id }
                            saveIgnoredApps()
                        }.labelStyle(.iconOnly)
                    }
                }
                Button("Add Application…", systemImage: "plus") { chooseApps() }
                HStack {
                    TextField("Or enter an app bundle ID", text: $newID).onSubmit { addID() }
                    Button("Add") { addID() }.disabled(newID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Copies from these apps are not saved. Password managers and Keychain Access are ignored by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keyboard: some View {
        Group {
            Section("Global Shortcut") {
                HStack {
                    Text("Open clipboard history")
                    Spacer()
                    ShortcutRecorder(label: hotKeyDisplay) { code, modifiers, label in
                        do {
                            try HotKeyManager.shared.register(keyCode: code, modifiers: modifiers)
                            UserDefaults.standard.set(Int(code), forKey: "hotKeyCode")
                            UserDefaults.standard.set(Int(modifiers), forKey: "hotKeyModifiers")
                            hotKeyDisplay = label
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .frame(width: 240, height: 30)
                }
                Text("Click the shortcut field and press your combination. Include Command, Control, or Option. Escape cancels. Conflicting shortcuts are rejected without changing the saved setting.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to ⌘⇧V") {
                    do {
                        try HotKeyManager.shared.register(keyCode: 9, modifiers: 768)
                        UserDefaults.standard.set(9, forKey: "hotKeyCode")
                        UserDefaults.standard.set(768, forKey: "hotKeyModifiers")
                        hotKeyDisplay = "⌘⇧V"
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            Section("History Window") {
                LabeledContent("Search", value: "⌘F")
                LabeledContent("Move between items", value: "↑ / ↓")
                LabeledContent("Use selected item", value: "Return")
                LabeledContent("Close window", value: "Escape")
            }
        }
    }

    private func policyChanged() {
        NotificationCenter.default.post(name: .historyPolicyChanged, object: nil)
    }

    private func saveIgnoredApps() { UserDefaults.standard.set(ignoredIDs.sorted(), forKey: "ignoredBundleIDs") }

    private func addID() {
        let id = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !ignoredIDs.contains(id) else { return }
        ignoredIDs.append(id)
        newID = ""
        saveIgnoredApps()
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ignoredIDs.contains(id) { ignoredIDs.append(id) }
        }
        saveIgnoredApps()
    }
}
