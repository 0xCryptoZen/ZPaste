import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "General", history = "History", privacy = "Privacy", keyboard = "Keyboard Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .history: return "clock.arrow.circlepath"
            case .privacy: return "hand.raised"
            case .keyboard: return "keyboard"
            }
        }
    }

    var onClose: () -> Void = {}
    @ObservedObject private var vault = VaultSession.shared
    @State private var page: Page? = .general
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()
    @State private var ignoredIDs = UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? []
    @State private var newID = ""
    @State private var errorMessage: String?
    @State private var confirmClear = false
    @State private var confirmDeleteAll = false
    @State private var confirmPolicy = false
    @State private var proposedDays = 7
    @State private var proposedLimit = 500
    @AppStorage("legacyPolicyPending") private var legacyPolicyPending = false
    @AppStorage("pasteOnClick") private var pasteOnClick = true
    @AppStorage("retentionDays") private var retentionDays = 7
    @AppStorage("historyLimit") private var historyLimit = 500
    @AppStorage("capturePaused") private var paused = false
    @AppStorage("mergeDuplicates") private var mergeDuplicates = true
    @AppStorage("ignoreConfidential") private var ignoreConfidential = true
    @AppStorage("ignoreTransient") private var ignoreTransient = true
    @AppStorage("hotKeyDisplay") private var hotKeyDisplay = "⌘⇧V"

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
                    .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .navigationTitle("ZPaste")
            .navigationSplitViewColumnWidth(min: 180, ideal: 195, max: 230)
        } detail: {
            Form {
                switch page ?? .general {
                case .general: general
                case .history: history
                case .privacy: privacy
                case .keyboard: keyboard
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .navigationTitle((page ?? .general).rawValue)
        }
        .frame(minWidth: 740, idealWidth: 800, minHeight: 540, idealHeight: 620)
        .background {
            Button("Close Settings", action: onClose).keyboardShortcut("w", modifiers: .command).hidden()
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onChange(of: paused) { _, _ in vault.updateMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("ZPaste", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Clear all unpinned history?", isPresented: $confirmClear) {
            Button("Clear Unpinned History", role: .destructive) {
                Task { _ = await vault.mutate { try await $0.clear(includePinned: false) } }
            }
        } message: { Text("This cannot be undone. Pinned items and folders will be kept.") }
        .confirmationDialog("Delete ALL history, including pins and folders?", isPresented: $confirmDeleteAll) {
            Button("Authenticate and Delete Everything", role: .destructive) { vault.deleteEverything() }
        } message: { Text("You must verify your identity again. This cannot be undone. Existing backups and past iCloud copies are not erased.") }
        .confirmationDialog("Apply these history limits?", isPresented: $confirmPolicy) {
            Button("Apply and Clean History", role: .destructive) {
                retentionDays = proposedDays; historyLimit = proposedLimit
                legacyPolicyPending = false
                policyChanged()
            }
        } message: { Text("Older or excess unpinned history will be removed immediately. Pinned items are kept.") }
    }

    private var general: some View {
        Group {
            Section("Startup & Recording") {
                Toggle(isOn: $launchAtLogin) {
                    Text("Open at login")
                    Text("Keep ZPaste ready in the menu bar.").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Open at Login")
                .accessibilityHint("Keep ZPaste ready in the menu bar.")
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
                        }
                    }
                Toggle(isOn: $paused) {
                    Text("Pause recording")
                    Text("Existing history stays available.").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Pause Recording")
                .accessibilityHint("Existing history stays available.")
                Toggle("Merge duplicate text", isOn: $mergeDuplicates)
                Text("Copying the same text again moves its existing entry to the top and keeps its pin and folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clicking a History Item") {
                Picker("Action", selection: $pasteOnClick) {
                    Text("Paste into the previous app").tag(true)
                    Text("Copy to clipboard only").tag(false)
                }
                Text("Choose an input field before opening ZPaste. Items are pasted as plain text.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(trusted ? "Accessibility enabled" : "Allow direct paste",
                          systemImage: trusted ? "checkmark.circle" : "exclamationmark.circle")
                    Spacer()
                    Button("Open Settings…") { PasteController.openAccessibilitySettings() }
                }
            }
            Section("Local Encrypted Storage") {
                Label(vault.isUnlocked ? "Unlocked · Stored only on this Mac" : "Locked · Recording stopped", systemImage: "lock.shield")
                Text("AES-256-GCM encryption. A device-only Keychain key requires Touch ID or your system password. No iCloud sync, analytics, or plaintext export.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = vault.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                Button(vault.isUnlocked ? "Lock Now" : "Unlock History") {
                    if vault.isUnlocked { vault.lock() } else { vault.unlock() }
                }.disabled(vault.state == .unlocking)
                Text("Direct paste uses Accessibility access. This build does not claim full App Sandbox isolation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var history: some View {
        Group {
            Section("Keep History") {
                if legacyPolicyPending {
                    Label("Your old history and limits were preserved", systemImage: "info.circle")
                    Button("Use Recommended Limits: 7 Days / 500 Items…") {
                        proposedDays = 7; proposedLimit = 500; confirmPolicy = true
                    }
                }
                Picker("Retention", selection: Binding(get: { retentionDays }, set: {
                    proposedDays = $0; proposedLimit = historyLimit; confirmPolicy = true
                })) {
                    Text("1 day").tag(1)
                    Text("1 week").tag(7)
                    Text("1 month (30 days)").tag(30)
                    Text("1 year (365 days)").tag(365)
                    Text("Forever").tag(0)
                }
                Picker("Maximum unpinned items", selection: Binding(get: { historyLimit }, set: {
                    proposedDays = retentionDays; proposedLimit = $0; confirmPolicy = true
                })) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1,000").tag(1_000)
                    Text("5,000").tag(5_000)
                    Text("Unlimited").tag(0)
                }
                Text("Applies to unpinned items, including those in folders. Shortening these limits immediately removes older history.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("New text: up to 256 KiB. Encrypted payload capacity: 20 MiB. Existing oversized history is preserved, but recording stops until it fits.")
                    .font(.caption).foregroundStyle(.secondary)
                if vault.isUnlocked {
                    LabeledContent("Encrypted payload", value: ByteCountFormatter.string(fromByteCount: Int64(vault.summary.payloadBytes), countStyle: .file))
                }
                Button("Clear Unpinned History…", role: .destructive) { confirmClear = true }.disabled(!vault.isUnlocked)
                Button("Delete ALL History…", role: .destructive) { confirmDeleteAll = true }.disabled(!vault.isUnlocked || UIPreviewData.enabled)
            }
            Section("Pinned Items") {
                Label("Pins stay until you remove them", systemImage: "pin")
                Text("Pins are excluded from retention and unpinned clearing. Up to 100 new pins; existing excess pins are preserved. Delete ALL History includes pins and folders.")
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
                Text("Filters future copies only. Existing history is unchanged. Source detection cannot reliably identify all passwords, private keys, or recovery phrases.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored Apps") {
                ForEach(ignoredIDs, id: \.self) { id in
                    HStack(spacing: 12) {
                        let app = SourceApplication.info(for: id)
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                        } else {
                            Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary).frame(width: 30, height: 30)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.callout)
                            if app.name != id { Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer()
                        Button {
                            ignoredIDs.removeAll { $0 == id }
                            saveIgnoredApps()
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove \(app.name)")
                        .accessibilityLabel("Remove \(app.name) from ignored apps")
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Application…", systemImage: "plus") { chooseApps() }
                HStack {
                    TextField("Or enter an app bundle ID", text: $newID).onSubmit { addID() }
                    Button("Add") { addID() }.disabled(newID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Future copies from these apps will not be saved. Changes do not remove existing history.")
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
                            if !UIPreviewData.enabled { try HotKeyManager.shared.register(keyCode: code, modifiers: modifiers) }
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
                        if !UIPreviewData.enabled { try HotKeyManager.shared.register(keyCode: 9, modifiers: 768) }
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
                LabeledContent("Preview selected item", value: "Space")
                LabeledContent("Settings", value: "⌘,")
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
