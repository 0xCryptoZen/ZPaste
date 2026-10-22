import AppKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Clip.createdAt, order: .reverse) private var recentClips: [Clip]
    @AppStorage("capturePaused") private var paused = false
    @AppStorage("hotKeyDisplay") private var shortcut = "⌘⇧V"
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .showHistoryWindow, object: nil)
                dismiss()
            } label: {
                HStack { Label("Open History", systemImage: "clock"); Spacer(); Text(shortcut).foregroundStyle(.secondary) }
            }
            Divider()
            if recentClips.isEmpty {
                Text("Copy text to get started").foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                Text("Recent · click to use").font(.caption).foregroundStyle(.secondary)
                ForEach(recentClips.prefix(10)) { clip in
                    Button {
                        dismiss()
                        PasteController.shared.select(clip.text)
                    } label: {
                        HStack {
                            if clip.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                            Text(clip.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Copy Only") { PasteController.shared.copy(clip.text) } }
                }
            }
            Divider()
            Button(paused ? "Resume Recording" : "Pause Recording", systemImage: paused ? "play" : "pause") { paused.toggle() }
            Button("Settings…", systemImage: "gearshape") { showingSettings = true }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12).frame(width: 360)
        .onAppear { PasteController.shared.rememberFrontmostApplication() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}
