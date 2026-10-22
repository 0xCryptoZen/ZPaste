import AppKit
import SwiftUI

struct VaultLockedView: View {
    @ObservedObject private var vault = VaultSession.shared
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 38)).foregroundStyle(.secondary)
            Text(vault.state == .deleting ? "Deleting History…" : (vault.state == .unlocking ? "Unlocking History…" : "History Is Locked")).font(.title2.weight(.semibold))
            Text("History stays encrypted on this Mac. Unlock with Touch ID or your system password to view it and record future copies.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 370)
            if let error = vault.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if vault.state == .unlocking || vault.state == .deleting {
                ProgressView().controlSize(.small)
                Button("Cancel") { vault.lock() }
            } else {
                Button("Unlock History") { vault.unlock() }.buttonStyle(.borderedProminent)
            }
            Text("Recording is stopped while locked.").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryView: View {
    @ObservedObject private var vault = VaultSession.shared
    var body: some View {
        Group {
            if vault.isUnlocked { UnlockedHistoryView() }
            else { VaultLockedView() }
        }.frame(minWidth: 780, minHeight: 500)
    }
}

private struct UnlockedHistoryView: View {
    @ObservedObject private var vault = VaultSession.shared
    @ObservedObject private var status = AppStatus.shared
    @StateObject private var model = HistoryViewModel()
    @State private var scope: HistoryScope? = .all
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var offset = 0
    @State private var previousOffsets: [Int] = []
    @State private var searchPresented = false
    @State private var showingFolderEditor = false
    @State private var editingFolder: FolderItem?
    @State private var deletingFolder: FolderItem?
    @State private var preview: ClipItem?
    @State private var confirmClear = false
    @AppStorage("capturePaused") private var paused = false
    @FocusState private var listFocused: Bool
    private var query: HistoryQuery { HistoryQuery(revision: vault.revision, scope: scope ?? .all, search: search, offset: offset) }
    private var selected: ClipItem? { model.page.clips.first { $0.id == selectedID } }
    private var title: String {
        switch scope ?? .all {
        case .all: return "All History"
        case .pinned: return "Pinned"
        case .folder(let id): return vault.summary.folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    var body: some View {
        NavigationSplitView { sidebar } detail: { detail }
        .toolbar { historyToolbar }
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Search encrypted history")
        .onSubmit(of: .search) { listFocused = true }
        .task(id: query) { await model.load(scope: scope ?? .all, search: search, offset: offset) }
        .onChange(of: scope) { _, _ in resetPage() }
        .onChange(of: search) { _, _ in resetPage() }
        .onChange(of: model.page.clips.map(\.id), initial: true) { _, ids in selectedID = ClipboardPresentation.selection(selectedID, in: ids) }
        .onDisappear { model.clear(); preview = nil }
        .background { Button("Search") { searchPresented = true }.keyboardShortcut("f", modifiers: .command).hidden() }
        .sheet(item: $preview) { ClipPreviewView(clip: $0) }
        .sheet(isPresented: $showingFolderEditor) {
            FolderEditorView(name: editingFolder?.name ?? "", isRenaming: editingFolder != nil) { name in
                let id = editingFolder?.id
                return await vault.mutate { try await $0.saveFolder(id: id, name: name) }
            }
        }
        .confirmationDialog("Delete this folder? Its items will remain in All History.", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        )) {
            Button("Delete Folder", role: .destructive) {
                if let id = deletingFolder?.id {
                    scope = .all
                    Task { _ = await vault.mutate { try await $0.delete(id) } }
                }
                deletingFolder = nil
            }
        }
        .confirmationDialog("Clear unpinned history? Pins and folders will be kept.", isPresented: $confirmClear) {
            Button("Clear Unpinned History", role: .destructive) {
                Task { _ = await vault.mutate { try await $0.clear(includePinned: false) } }
            }
        }
    }

    private var sidebar: some View {
            List(selection: $scope) {
                Section("Library") {
                    Label("All History", systemImage: "tray.full").badge(vault.summary.count).tag(HistoryScope.all)
                    Label("Pinned", systemImage: "pin").badge(vault.summary.pinned).tag(HistoryScope.pinned)
                }
                Section("Folders") {
                    ForEach(vault.summary.folders) { folder in
                        Label(folder.name, systemImage: "folder").badge(folder.count).tag(HistoryScope.folder(folder.id))
                            .contextMenu {
                                Button("Rename…") { editingFolder = folder; showingFolderEditor = true }
                                Button("Delete Folder…", role: .destructive) { deletingFolder = folder }
                            }
                    }
                }
            }
            .listStyle(.sidebar).navigationTitle("ZPaste")
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("New Folder", systemImage: "plus") { editingFolder = nil; showingFolderEditor = true }
                    Spacer()
                    Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                }.buttonStyle(.borderless).padding(14)
            }
    }

    private var detail: some View {
            VStack(spacing: 0) {
                if UIPreviewData.enabled {
                    Label("UI Preview · Sample data only · Clipboard unchanged", systemImage: "eye")
                        .font(.caption).padding(12).frame(maxWidth: .infinity).background(.orange.opacity(0.12))
                }
                if model.page.clips.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No History Here" : "No Results", systemImage: search.isEmpty ? "clipboard" : "magnifyingglass",
                        description: Text(paused ? "Recording is paused. Resume to save future copies." : "Copy text or choose a different search or folder."))
                } else {
                    historyList
                }
                Divider()
                footer
                if let error = status.errorMessage {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                        Spacer()
                        Button("Dismiss") { status.errorMessage = nil }
                    }.padding(12).background(.bar)
                }
            }.navigationTitle(title)
    }

    private var historyList: some View {
                    List(selection: $selectedID) {
                        ForEach(HistorySection.allCases) { section in
                            let items = model.page.clips.filter { ClipboardPresentation.section(createdAt: $0.createdAt, pinned: $0.isPinned) == section }
                            if !items.isEmpty {
                                Section(section.rawValue) {
                                    ForEach(items) { clip in
                                        ClipRowView(clip: clip, folders: vault.summary.folders) { selectedID = clip.id } onPreview: {
                                            selectedID = clip.id; preview = clip
                                        }.tag(clip.id)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset).focused($listFocused)
                    .onKeyPress(.return) { useSelected(); return .handled }
                    .onKeyPress(.space) { preview = selected; return .handled }
                    .onKeyPress(.escape) { NSApp.hide(nil); return .handled }
    }

    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { preview = selected } label: { Label("Preview", systemImage: "eye") }.disabled(selected == nil)
                Button { if let selected { vault.use(selected.id, copyOnly: true) } } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(selected == nil)
                Button { paused.toggle(); vault.updateMonitoring() } label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.circle" : "pause.circle") }
                Button { vault.lock() } label: { Label("Lock", systemImage: "lock") }
                Menu {
                    Button("New Folder…") { editingFolder = nil; showingFolderEditor = true }
                    Button("Settings…") { openSettings() }.keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Button("Clear Unpinned History…", role: .destructive) { confirmClear = true }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(paused ? "Paused" : "Local · Encrypted", systemImage: paused ? "pause.circle" : "lock.shield")
            if model.loading { ProgressView().controlSize(.mini) }
            Spacer()
            Button("Previous") { if let previous = previousOffsets.popLast() { offset = previous } }.disabled(previousOffsets.isEmpty)
            Button("Next") { if let next = model.page.nextOffset { previousOffsets.append(offset); offset = next } }.disabled(model.page.nextOffset == nil)
            Text(status.feedback ?? "Select · Return to use · Space to preview").lineLimit(1)
        }.font(.caption).padding(.horizontal, 16).padding(.vertical, 9).background(.bar)
    }
    private func resetPage() { offset = 0; previousOffsets = [] }
    private func useSelected() { if let selected { vault.use(selected.id) } }
    private func openSettings() { NotificationCenter.default.post(name: .showSettingsWindow, object: nil) }
}
