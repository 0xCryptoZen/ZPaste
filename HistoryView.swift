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
    private enum Scope: Hashable {
        case all, pinned, folder(PersistentIdentifier)
    }
    @State private var scope: Scope? = .all
    @State private var selectedClipID: PersistentIdentifier?
    @State private var showingFolderEditor = false
    @State private var editingFolder: Folder?
    @State private var deletingFolder: Folder?
    @State private var confirmClear = false
    @State private var searchPresented = false
    @State private var previewClip: Clip?
    @FocusState private var listFocused: Bool

    private var filteredClips: [Clip] {
        allClips.filter { clip in
            matchesScope(clip) &&
            (searchText.isEmpty || clip.text.localizedCaseInsensitiveContains(searchText))
        }.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if UIPreviewData.enabled {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "eye").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("UI Preview").fontWeight(.semibold)
                            Text("Sample history only. Clipboard recording and pasting are disabled. Open ZPaste.app from the downloaded build for normal use.")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                }
                if filteredClips.isEmpty { emptyState }
                else { historyList }
                Divider()
                footer
                if let error = status.errorMessage { errorBanner(error) }
            }
            .navigationTitle(UIPreviewData.enabled ? "\(scopeTitle) · UI Preview" : scopeTitle)
        }
        .frame(minWidth: 780, minHeight: 500)
        .toolbar { historyToolbar }
        .searchable(text: $searchText, isPresented: $searchPresented, placement: .toolbar, prompt: "Search history")
        .onSubmit(of: .search) { listFocused = true }
        .onChange(of: filteredClips.map(\.persistentModelID), initial: true) { _, ids in
            selectedClipID = ClipboardPresentation.selection(selectedClipID, in: ids)
        }
        .background {
            Button("Search") { searchPresented = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .sheet(isPresented: $showingFolderEditor) {
            FolderEditorView(name: editingFolder?.name ?? "", isRenaming: editingFolder != nil) { name in
                saveFolder(name)
            }
        }
        .sheet(item: $previewClip) { ClipPreviewView(clip: $0) }
        .confirmationDialog("Delete this folder?", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        )) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = deletingFolder else { return }
                if scope == .folder(folder.persistentModelID) { scope = .all }
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

    }

    private var sidebar: some View {
        List(selection: $scope) {
            Section("Library") {
                Label("All History", systemImage: "tray.full").badge(allClips.count).tag(Scope.all)
                Label("Pinned", systemImage: "pin").badge(allClips.filter(\.isPinned).count).tag(Scope.pinned)
            }
            Section("Folders") {
                ForEach(folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(allClips.filter { $0.folder?.persistentModelID == folder.persistentModelID }.count)
                        .tag(Scope.folder(folder.persistentModelID))
                        .contextMenu {
                            Button("Rename…") { editingFolder = folder; showingFolderEditor = true }
                            Button("Delete Folder…", role: .destructive) { deletingFolder = folder }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ZPaste")
        .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { editingFolder = nil; showingFolderEditor = true } label: {
                    Label("New Folder", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
            }
            .font(.callout).foregroundStyle(.secondary).padding(14)
        }
    }

    private var historyList: some View {
        List(selection: $selectedClipID) {
            ForEach(HistorySection.allCases) { section in
                let items = filteredClips.filter {
                    ClipboardPresentation.section(createdAt: $0.createdAt, pinned: $0.isPinned) == section
                }
                if !items.isEmpty {
                    Section(section.rawValue) {
                        ForEach(items) { clip in
                            ClipRowView(clip: clip, folders: folders) {
                                selectedClipID = clip.persistentModelID
                                paste.select(clip.text)
                            } onPreview: {
                                selectedClipID = clip.persistentModelID
                                previewClip = clip
                            }
                            .tag(clip.persistentModelID)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .onKeyPress(.return) { useSelectedItem(); return .handled }
        .onKeyPress(.space) {
            previewClip = selectedClip
            return .handled
        }
        .onKeyPress(.escape) { NSApp.hide(nil); return .handled }
    }

    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { previewClip = selectedClip } label: { Label("Preview", systemImage: "eye") }
                .disabled(selectedClip == nil).help("Preview Full Text (Space)")
            Button { paused.toggle() } label: {
                Label(paused ? "Resume Recording" : "Pause Recording", systemImage: paused ? "play.circle" : "pause.circle")
            }
            .help(paused ? "Resume Recording" : "Pause Recording")
            Menu {
                Button("New Folder…", systemImage: "folder.badge.plus") { editingFolder = nil; showingFolderEditor = true }
                Button("Export Displayed Items…", systemImage: "square.and.arrow.up") { exportItems() }.disabled(filteredClips.isEmpty)
                Divider()
                if UIPreviewData.enabled {
                    Menu("Preview Appearance") {
                        Button("Light") { NSApp.appearance = NSAppearance(named: .aqua) }
                        Button("Dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                        Divider()
                        Button("Compact Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 800, height: 520)) }
                    }
                }
                Button("Settings…", systemImage: "gearshape") { openSettings() }.keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Clear Unpinned History…", systemImage: "trash", role: .destructive) { confirmClear = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .help("History Actions")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? (scope == .pinned ? "No Pinned Items" : "No History Yet") : "No Results",
                  systemImage: searchText.isEmpty ? (scope == .pinned ? "pin" : "clipboard") : "magnifyingglass")
        } description: {
            Text(searchText.isEmpty ? (paused ? "Recording is paused. Resume to save new copies." : "Copied text will appear here. Pin items to keep them handy.") : "Try another search or choose a different folder.")
        } actions: {
            if !searchText.isEmpty { Button("Clear Search") { searchText = "" } }
            else if paused { Button("Resume Recording") { paused = false } }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(UIPreviewData.enabled ? "Preview · Not Recording" : (paused ? "Paused" : "Recording"),
                  systemImage: UIPreviewData.enabled ? "eye" : (paused ? "pause.circle" : "checkmark.circle"))
                .foregroundStyle(UIPreviewData.enabled || paused ? Color.orange : Color.secondary)
            Text("·")
            Text("\(filteredClips.count.formatted()) \(filteredClips.count == 1 ? "item" : "items")")
            Spacer()
            Text(status.feedback ?? (UIPreviewData.enabled ? "System clipboard unchanged" : (pasteOnClick ? "Click to paste into \(paste.targetName)" : "Click to copy")))
                .lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        .background(.bar)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.caption).textSelection(.enabled)
            Spacer()
            Button { status.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss Error")
        }
        .padding(12).background(.regularMaterial)
    }

    private var scopeTitle: String {
        switch scope ?? .all {
        case .all: return "All History"
        case .pinned: return "Pinned"
        case .folder(let id): return folders.first { $0.persistentModelID == id }?.name ?? "Folder"
        }
    }

    private var selectedClip: Clip? { filteredClips.first { $0.persistentModelID == selectedClipID } }

    private func matchesScope(_ clip: Clip) -> Bool {
        switch scope ?? .all {
        case .all: return true
        case .pinned: return clip.isPinned
        case .folder(let id): return clip.folder?.persistentModelID == id
        }
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .showSettingsWindow, object: nil)
    }

    private func useSelectedItem() {
        let clip = filteredClips.first { $0.persistentModelID == selectedClipID } ?? filteredClips.first
        if let clip { paste.select(clip.text) }
    }

    private func saveFolder(_ name: String) -> Bool {
        if let editingFolder { editingFolder.name = name }
        else { context.insert(Folder(name: name)) }
        do { try context.save(); return true }
        catch { context.rollback(); status.errorMessage = error.localizedDescription; return false }
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
