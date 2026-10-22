import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Clip.createdAt, order: .reverse) private var allClips: [Clip]
    @Query(sort: \Folder.name) private var folders: [Folder]
    @ObservedObject private var paste = PasteController.shared
    @ObservedObject private var status = AppStatus.shared
    @AppStorage("capturePaused") private var paused = false
    @AppStorage("pasteOnClick") private var pasteOnClick = true
    @State private var searchText = ""
    @State private var selectedFolderID: PersistentIdentifier?
    @State private var selectedClipID: PersistentIdentifier?
    @State private var pinnedOnly = false
    @State private var showingSettings = false
    @State private var showingFolderEditor = false
    @State private var editingFolder: Folder?
    @State private var deletingFolder: Folder?
    @State private var folderName = ""
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var filteredClips: [Clip] {
        allClips.filter { clip in
            (!pinnedOnly || clip.isPinned) &&
            (selectedFolderID == nil || clip.folder?.persistentModelID == selectedFolderID) &&
            (searchText.isEmpty || clip.text.localizedCaseInsensitiveContains(searchText))
        }.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Button { selectedFolderID = nil; pinnedOnly = false } label: {
                    Label("All (\(allClips.count))", systemImage: "tray")
                }.buttonStyle(.plain)
                Button { selectedFolderID = nil; pinnedOnly = true } label: {
                    Label("Pinned (\(allClips.filter(\.isPinned).count))", systemImage: "pin")
                }.buttonStyle(.plain)
                Section("Folders") {
                    ForEach(folders) { folder in
                        Button { selectedFolderID = folder.persistentModelID; pinnedOnly = false } label: {
                            Label(folder.name, systemImage: "folder")
                                .foregroundStyle(selectedFolderID == folder.persistentModelID ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") { editingFolder = folder; folderName = folder.name; showingFolderEditor = true }
                            Button("Delete Folder…", role: .destructive) { deletingFolder = folder }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if filteredClips.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No History" : "No Results",
                        systemImage: searchText.isEmpty ? "clipboard" : "magnifyingglass",
                        description: Text(paused ? "Recording is paused. Resume to save new copies." : "Copy text or change the search and folder filters.")
                    )
                } else {
                    List(selection: $selectedClipID) {
                        ForEach(filteredClips) { clip in
                            ClipRow(clip: clip, folders: folders) {
                                selectedClipID = clip.persistentModelID
                                paste.select(clip.text)
                            }
                            .tag(clip.persistentModelID)
                        }
                    }
                    .onKeyPress(.return) { useSelectedItem(); return .handled }
                }
                Divider()
                footer
                if let error = status.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { status.errorMessage = nil }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onKeyPress(.escape) { NSApp.hide(nil); return .handled }
        .background {
            Button("Search") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .alert(editingFolder == nil ? "New Folder" : "Rename Folder", isPresented: $showingFolderEditor) {
            TextField("Name", text: $folderName)
            Button("Save") { saveFolder() }
            Button("Cancel", role: .cancel) { editingFolder = nil; folderName = "" }
        }
        .confirmationDialog("Delete this folder?", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        )) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = deletingFolder else { return }
                if selectedFolderID == folder.persistentModelID { selectedFolderID = nil }
                context.delete(folder)
                save()
                deletingFolder = nil
            }
        } message: { Text("Its history items will remain in All.") }
        .confirmationDialog("Clear all unpinned history?", isPresented: $confirmClear) {
            Button("Clear Unpinned History", role: .destructive) {
                do { try HistoryMaintenance.clearUnpinned(in: context) }
                catch { context.rollback(); status.errorMessage = error.localizedDescription }
            }
        } message: { Text("This cannot be undone. Pinned items and folders will be kept.") }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private var toolbar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search…", text: $searchText)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { useSelectedItem() }
            Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                .help(paused ? "Resume Recording" : "Pause Recording")
                .accessibilityLabel(paused ? "Resume Recording" : "Pause Recording")
            Button { editingFolder = nil; folderName = ""; showingFolderEditor = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New Folder").accessibilityLabel("New Folder")
            Menu {
                Button("Export Displayed Items…") { exportItems() }.disabled(filteredClips.isEmpty)
                Button("Clear Unpinned History…", role: .destructive) { confirmClear = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .help("Manage History").accessibilityLabel("Manage History")
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings").accessibilityLabel("Settings")
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text("\(filteredClips.count) items")
            if paused { Label("Recording paused", systemImage: "pause.circle") }
            Spacer()
            Text(pasteOnClick ? "Click to paste into \(paste.targetName)" : "Click to copy")
        }
        .font(.caption).foregroundStyle(.secondary).padding(10)
    }

    private func useSelectedItem() {
        let clip = filteredClips.first { $0.persistentModelID == selectedClipID } ?? filteredClips.first
        if let clip { paste.select(clip.text) }
    }

    private func saveFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let editingFolder { editingFolder.name = name }
        else { context.insert(Folder(name: name)) }
        save()
        editingFolder = nil
        folderName = ""
    }

    private func save() {
        do { try context.save() }
        catch { context.rollback(); status.errorMessage = error.localizedDescription }
    }

    private func exportItems() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ZPaste-history.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try filteredClips.map(\.text).joined(separator: "\n\n---\n\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { status.errorMessage = "Could not export history: \(error.localizedDescription)" }
    }
}

private struct ClipRow: View {
    @Environment(\.modelContext) private var context
    let clip: Clip
    let folders: [Folder]
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(clip.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text(clip.createdAt, style: .relative)
                        if let id = clip.sourceAppBundleID {
                            Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id)
                        }
                        if let folder = clip.folder { Label(folder.name, systemImage: "folder") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Use this history item")
            Button { clip.isPinned.toggle(); save() } label: {
                Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(clip.isPinned ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(clip.isPinned ? "Unpin" : "Pin")
            .accessibilityLabel(clip.isPinned ? "Unpin" : "Pin")
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Paste into Previous App") { PasteController.shared.select(clip.text, forcePaste: true) }
            Button("Copy Only") { PasteController.shared.copy(clip.text) }
            Menu("Move to Folder") {
                Button("None") { clip.folder = nil; save() }
                ForEach(folders) { folder in Button(folder.name) { clip.folder = folder; save() } }
            }
            Divider()
            Button("Delete", role: .destructive) { context.delete(clip); save() }
        }
    }

    private func save() {
        do { try context.save() }
        catch { context.rollback(); AppStatus.shared.errorMessage = error.localizedDescription }
    }
}
