import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var ignoredIDs: [String] =
        UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? []
    @State private var newID = ""

    var body: some View {
        Form {
            Section("开机自启") {
                Toggle("登录时启动", isOn: $launchAtLogin)
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

            Section("忽略的 App（复制时不记录）") {
                HStack {
                    TextField("bundle id，例如 com.1password.1password", text: $newID)
                        .onSubmit { addID() }
                    Button("添加", action: addID)
                }
                if ignoredIDs.isEmpty {
                    Text("为空：记录所有 App 的复制内容。").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(ignoredIDs, id: \.self) { id in
                        HStack {
                            Text(id).textSelection(.enabled)
                            Spacer()
                            Button("移除") {
                                ignoredIDs.removeAll { $0 == id }
                                save()
                            }
                        }
                    }
                }
            }

            Section("iCloud 同步") {
                Text("数据通过 CloudKit 自动同步。首次使用需在 Xcode 的 Signing & Capabilities 中开启 iCloud 能力，选择 CloudKit 并指定容器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("全局快捷键") {
                Text("⌘⇧V 呼出历史窗口（当前为固定快捷键，后续版本可自定义）。")
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
