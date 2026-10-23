import AppKit
import SwiftUI

struct MenuBarView: View {
    var body: some View { QuickPasteView().frame(width: 500, height: 540) }
}

struct QuickPasteView: View {
    @ObservedObject private var vault = VaultSession.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("ZPaste", systemImage: "doc.on.clipboard").font(.headline)
                Spacer()
                if vault.isUnlocked {
                    Button { vault.lock() } label: { Image(systemName: "lock") }.help("Lock History")
                }
                Button { NotificationCenter.default.post(name: .showSettingsWindow, object: nil) } label: { Image(systemName: "gearshape") }.help("Settings")
            }.buttonStyle(.borderless).padding(16)
            Divider()
            if vault.isUnlocked { UnlockedQuickPasteView() }
            else { VaultLockedView() }
            Divider()
            HStack {
                Button("Open History") { NotificationCenter.default.post(name: .showHistoryWindow, object: nil) }
                Spacer()
                Text("Local encrypted history").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Settings…") { NotificationCenter.default.post(name: .showSettingsWindow, object: nil) }
                    Divider()
                    Button("Quit ZPaste") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            }.padding(12)
        }
    }
}

private struct UnlockedQuickPasteView: View {
    @ObservedObject private var vault = VaultSession.shared
    @ObservedObject private var status = AppStatus.shared
    @ObservedObject private var paste = PasteController.shared
    @AppStorage("pasteOnClick") private var pasteOnClick = true
    @StateObject private var model = HistoryViewModel()
    @State private var search = ""
    @State private var selection: UUID?
    @AppStorage("capturePaused") private var paused = false
    @FocusState private var searching: Bool
    private var items: [ClipItem] { search.isEmpty ? vault.recent : model.page.clips }
    private var query: HistoryQuery { HistoryQuery(revision: vault.revision, scope: .all, search: search, offset: 0) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $search).textFieldStyle(.plain).focused($searching).onSubmit { useSelected() }
                if model.loading { ProgressView().controlSize(.mini) }
                Button { paused.toggle(); vault.updateMonitoring() } label: { Image(systemName: paused ? "play.circle" : "pause.circle") }
                    .buttonStyle(.borderless).help(paused ? "Resume Recording" : "Pause Recording")
            }.padding(14)
            if items.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Nothing Copied Yet" : "No Results", systemImage: "clipboard",
                    description: Text(paused ? "Recording is paused." : "Future copies appear here while unlocked."))
            } else {
                List(selection: $selection) {
                    ForEach(items) { clip in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(clip.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text(SourceApplication.info(for: clip.sourceAppBundleID).name).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5).contentShape(Rectangle()).tag(clip.id)
                        .onTapGesture(count: 2) { selection = clip.id; useSelected() }
                        .onTapGesture { selection = clip.id }
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text(status.errorMessage ?? status.feedback ?? (UIPreviewData.enabled ? "Preview · Clipboard unchanged" : (paused ? "Paused" : (pasteOnClick ? "Return: paste into \(paste.targetName) · Esc: close" : "Return: copy only · Esc: close"))))
                    .font(.caption).foregroundStyle(status.errorMessage == nil ? Color.secondary : Color.orange).lineLimit(2)
                Spacer()
            }.padding(12)
        }
        .onAppear { searching = true }
        .onDisappear { model.clear(); search = "" }
        .onChange(of: items.map(\.id), initial: true) { _, ids in selection = ClipboardPresentation.selection(selection, in: ids) }
        .task(id: query) {
            if !search.isEmpty { await model.load(scope: .all, search: search, limit: 8, byteLimit: VaultLimits.quickDisplayBytes) }
            else { model.clear() }
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { useSelected(); return .handled }
        .onKeyPress(.escape) { NSApp.hide(nil); return .handled }
    }
    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selection } ?? 0
        selection = items[min(max(index + delta, 0), items.count - 1)].id
    }
    private func useSelected() {
        if let selection { vault.use(selection) }
    }
}
