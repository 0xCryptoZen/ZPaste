import AppKit
import CoreGraphics
import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Clip.createdAt, order: .reverse) private var allClips: [Clip]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var searchText = ""
    @State private var selectedFolderID: PersistentIdentifier?
    @State private var showingSettings = false
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    private var filteredClips: [Clip] {
        var result = allClips
        if let id = selectedFolderID {
            result = result.filter { $0.folder?.persistentModelID == id }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Button {
                    selectedFolderID = nil
                } label: {
                    Label("All", systemImage: "tray")
                        .foregroundStyle(selectedFolderID == nil ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)

                ForEach(folders) { folder in
                    Button {
                        selectedFolderID = folder.persistentModelID
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .foregroundStyle(selectedFolderID == folder.persistentModelID ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 180)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search…", text: $searchText)
                        .textFieldStyle(.plain)
                    Spacer()
                    Button {
                        showingNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("New Folder")
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
                .padding(10)

                Divider()

                if filteredClips.isEmpty {
                    Spacer()
                    Text("Copy something and it will show up here").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(filteredClips) { clip in
                        ClipRow(clip: clip, folders: folders)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        context.insert(Folder(name: name))
        try? context.save()
    }
}

/// A single history entry.
private struct ClipRow: View {
    @Environment(\.modelContext) private var context
    let clip: Clip
    let folders: [Folder]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(clip.createdAt, style: .relative)
                        .foregroundStyle(.secondary)
                    if let name = appName(for: clip.sourceAppBundleID) {
                        Text(name).foregroundStyle(.secondary)
                    }
                    if clip.folder != nil {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button {
                togglePin()
            } label: {
                Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(clip.isPinned ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(clip.isPinned ? "Unpin" : "Pin")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") { copy() }
            Button("Copy & Paste to Frontmost App") { copyAndPaste() }
            Menu("Move to Folder") {
                Button("None") { move(to: nil) }
                ForEach(folders) { folder in
                    Button(folder.name) { move(to: folder) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { delete() }
        }
    }

    private func copy() {
        ClipboardMonitor.skipNextChange = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip.text, forType: .string)
    }

    private func copyAndPaste() {
        copy()
        // Requires the Accessibility permission; otherwise it only copies.
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // V
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func togglePin() {
        clip.isPinned.toggle()
        try? context.save()
    }

    private func move(to folder: Folder?) {
        clip.folder = folder
        try? context.save()
    }

    private func delete() {
        context.delete(clip)
        try? context.save()
    }

    private func appName(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
    }
}