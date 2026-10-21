import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var ignoredIDs: [String] =
        UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? []
    @State private var newID = ""

    var body: some View {
        Form {
            Section("Launch at Login") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Ignored Apps (not recorded)") {
                HStack {
                    TextField("Bundle ID, e.g. com.1password.1password", text: $newID)
                        .onSubmit { addID() }
                    Button("Add", action: addID)
                }
                if ignoredIDs.isEmpty {
                    Text("Empty: copies from all apps are recorded.").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(ignoredIDs, id: \.self) { id in
                        HStack {
                            Text(id).textSelection(.enabled)
                            Spacer()
                            Button("Remove") {
                                ignoredIDs.removeAll { $0 == id }
                                save()
                            }
                        }
                    }
                }
            }

            Section("iCloud Sync") {
                Text("Data syncs automatically via CloudKit. To enable it, add the iCloud capability (CloudKit) in Xcode's Signing & Capabilities and specify a container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global Hotkey") {
                Text("Press ⌘⇧V to open the history window (fixed for now; customizable in a future version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 440, height: 360)
    }

    private func addID() {
        let id = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        newID = ""
        guard !id.isEmpty, !ignoredIDs.contains(id) else { return }
        ignoredIDs.append(id)
        save()
    }

    private func save() {
        UserDefaults.standard.set(ignoredIDs, forKey: "ignoredBundleIDs")
    }
}