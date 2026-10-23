import AppKit
import SwiftUI

@MainActor
enum SourceApplication {
    struct Info { var name: String; var icon: NSImage? }
    private static var cache: [String: Info] = [:]
    static func clear() { cache.removeAll() }
    static func info(for bundleID: String?) -> Info {
        guard let bundleID else { return Info(name: "Unknown App", icon: nil) }
        if let cached = cache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let icon: NSImage? = url.map {
            let original = NSWorkspace.shared.icon(forFile: $0.path)
            let small = NSImage(size: NSSize(width: 32, height: 32))
            small.lockFocus()
            original.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            small.unlockFocus()
            return small
        }
        let info = Info(name: url?.deletingPathExtension().lastPathComponent ?? bundleID, icon: icon)
        if cache.count >= 64 { cache.removeAll() }
        cache[bundleID] = info
        return info
    }
}

struct ClipRowView: View {
    let clip: ClipItem
    let folders: [FolderItem]
    let onSelect: () -> Void
    let onPreview: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ClipboardPresentation.isWebLink(clip.text) ? "link" : "text.alignleft")
                .font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 7) {
                Text(clip.text).font(.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    let source = SourceApplication.info(for: clip.sourceAppBundleID)
                    if let icon = source.icon { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
                    Text(source.name).lineLimit(1)
                    Text("·")
                    Text(clip.createdAt, style: .relative).lineLimit(1)
                    if let folder = folders.first(where: { $0.id == clip.folderID }) {
                        Text("·"); Label(folder.name, systemImage: "folder").lineLimit(1)
                    }
                    if clip.isPreviewOnly { Text("· Preview shortened") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Button {
                    Task { _ = await VaultSession.shared.mutate { try await $0.changeClip(clip.id, pinned: !clip.isPinned) } }
                } label: { Image(systemName: clip.isPinned ? "pin.fill" : "pin") }
                .help(clip.isPinned ? "Unpin" : "Pin").accessibilityLabel(clip.isPinned ? "Unpin" : "Pin")
                Button(action: onPreview) { Image(systemName: "eye") }
                    .help("Preview (Space)").accessibilityLabel("Preview Full Text")
                    .opacity(hovered ? 1 : 0)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8).padding(.horizontal, 4).contentShape(Rectangle())
        .onTapGesture(count: 2) { onSelect(); VaultSession.shared.use(clip.id) }
        .onTapGesture { onSelect() }
        .accessibilityAction(named: Text("Use Item")) { VaultSession.shared.use(clip.id) }
        .accessibilityAction(named: Text("Copy Only")) { VaultSession.shared.use(clip.id, copyOnly: true) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Paste into Previous App") { VaultSession.shared.use(clip.id, forcePaste: true) }
            Button("Copy Only") { VaultSession.shared.use(clip.id, copyOnly: true) }
            Button("Preview…", action: onPreview)
            Divider()
            Button(clip.isPinned ? "Unpin" : "Pin") {
                Task { _ = await VaultSession.shared.mutate { try await $0.changeClip(clip.id, pinned: !clip.isPinned) } }
            }
            Menu("Move to Folder") {
                Button("None") { move(to: nil) }
                ForEach(folders) { folder in Button(folder.name) { move(to: folder.id) } }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { _ = await VaultSession.shared.mutate { try await $0.delete(clip.id) } }
            }
        }
    }
    private func move(to folder: UUID?) {
        Task { _ = await VaultSession.shared.mutate { try await $0.changeClip(clip.id, folderID: .some(folder)) } }
    }
}

struct ClipPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let clip: ClipItem
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Clipboard Item", systemImage: "doc.text").font(.headline)
                Spacer()
                Text(clip.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView { Text(clip.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(20) }
            if clip.isPreviewOnly {
                Text("This legacy item's preview is shortened to protect memory. Copy or paste uses its complete stored text.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            Divider()
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Only") { VaultSession.shared.use(clip.id, copyOnly: true) }
                Button("Use Item") { dismiss(); VaultSession.shared.use(clip.id) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 360, idealHeight: 440)
    }
}

struct FolderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var saving = false
    @FocusState private var nameFocused: Bool
    let isRenaming: Bool
    let onSave: (String) async -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isRenaming ? "Rename Folder" : "New Folder", systemImage: "folder").font(.headline)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit { submit() }
            Text("Up to 256 UTF-8 bytes.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { submit() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 256)
            }
        }.padding(24).frame(width: 340).onAppear { nameFocused = true }
    }
    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving, !value.isEmpty, value.utf8.count <= 256 else { return }
        saving = true
        Task { if await onSave(value) { dismiss() }; saving = false }
    }
}
