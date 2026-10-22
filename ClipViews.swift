import AppKit
import SwiftData
import SwiftUI

@MainActor
enum SourceApplication {
    struct Info {
        var name: String
        var icon: NSImage?
    }
    private static var cache: [String: Info] = [:]

    static func info(for bundleID: String?) -> Info {
        guard let bundleID else { return Info(name: "Unknown App", icon: nil) }
        if let cached = cache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let info = Info(
            name: url?.deletingPathExtension().lastPathComponent ?? bundleID,
            icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        )
        cache[bundleID] = info
        return info
    }
}

struct ClipRowView: View {
    @Environment(\.modelContext) private var context
    @State private var hovered = false
    let clip: Clip
    let folders: [Folder]
    let onSelect: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: ClipboardPresentation.isWebLink(clip.text) ? "link" : "text.alignleft")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(clip.text)
                            .font(.body).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            let source = SourceApplication.info(for: clip.sourceAppBundleID)
                            if let icon = source.icon {
                                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                            }
                            Text(source.name).lineLimit(1)
                            Text("·")
                            Text(clip.createdAt, style: .relative).lineLimit(1)
                            if let folder = clip.folder {
                                Text("·")
                                Label(folder.name, systemImage: "folder").lineLimit(1)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Use this history item")
            VStack(spacing: 8) {
                Button { clip.isPinned.toggle(); save() } label: {
                    Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(clip.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 22)
                }
                .help(clip.isPinned ? "Unpin" : "Pin")
                .accessibilityLabel(clip.isPinned ? "Unpin" : "Pin")
                Button(action: onPreview) {
                    Image(systemName: "eye").frame(width: 24, height: 22)
                }
                .help("Preview Full Text")
                .accessibilityLabel("Preview Full Text")
                .opacity(hovered ? 1 : 0)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Paste into Previous App") { PasteController.shared.select(clip.text, forcePaste: true) }
            Button("Copy Only") { PasteController.shared.copy(clip.text) }
            Button("Preview Full Text…", action: onPreview)
            Divider()
            Button(clip.isPinned ? "Unpin" : "Pin") { clip.isPinned.toggle(); save() }
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

struct ClipPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pasteOnClick") private var pasteOnClick = true
    let clip: Clip

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: ClipboardPresentation.isWebLink(clip.text) ? "link" : "doc.text")
                    .font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clipboard Item").font(.headline)
                    Text("\(SourceApplication.info(for: clip.sourceAppBundleID).name) · \(clip.text.count.formatted()) characters")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(clip.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ScrollView {
                Text(clip.text)
                    .textSelection(.enabled).font(.body)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
            }
            .background(.background)
            Divider()
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Only") { PasteController.shared.copy(clip.text) }
                Button(pasteOnClick ? "Paste into Previous App" : "Copy to Clipboard") {
                    dismiss()
                    PasteController.shared.select(clip.text)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 360, idealHeight: 440)
    }
}

struct FolderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @FocusState private var nameFocused: Bool
    let isRenaming: Bool
    let onSave: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isRenaming ? "Rename Folder" : "New Folder", systemImage: "folder")
                .font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRenaming ? "Save" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 340)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && onSave(trimmed) { dismiss() }
    }
}
