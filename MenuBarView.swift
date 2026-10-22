import AppKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var status = AppStatus.shared
    @Query(sort: \Clip.createdAt, order: .reverse) private var recentClips: [Clip]
    @AppStorage("capturePaused") private var paused = false
    @AppStorage("pasteOnClick") private var pasteOnClick = true
    @AppStorage("hotKeyDisplay") private var shortcut = "⌘⇧V"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(UIPreviewData.enabled ? "ZPaste · UI Preview" : "ZPaste").font(.headline)
                    Text(status.feedback ?? (UIPreviewData.enabled ? "Sample data · Recording disabled" : (paused ? "Recording paused" : "Your clipboard, close at hand")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { paused.toggle() } label: {
                    Image(systemName: paused ? "play.circle" : "pause.circle").font(.title3)
                }
                .buttonStyle(.borderless).help(paused ? "Resume Recording" : "Pause Recording")
                .accessibilityLabel(paused ? "Resume Recording" : "Pause Recording")
            }
            .padding(16)
            Divider()
            if recentClips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clipboard").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Nothing copied yet").font(.headline)
                    Text(paused ? "Resume recording to save new copies." : "Copy text in any app to get started.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                HStack {
                    Text("Recent").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(UIPreviewData.enabled ? "Preview only" : (pasteOnClick ? "Click to paste" : "Click to copy"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recentClips.prefix(8)) { clip in
                            RecentClipButton(clip: clip) {
                                if pasteOnClick { dismiss() }
                                PasteController.shared.select(clip.text)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .frame(maxHeight: 340)
            }
            Divider()
            HStack {
                Button {
                    NotificationCenter.default.post(name: .showHistoryWindow, object: nil)
                    dismiss()
                } label: {
                    HStack { Text("Open History"); Text(shortcut).foregroundStyle(.secondary) }
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Settings…", systemImage: "gearshape") {
                        NotificationCenter.default.post(name: .showSettingsWindow, object: nil)
                        dismiss()
                    }
                    Button(paused ? "Resume Recording" : "Pause Recording") { paused.toggle() }
                    Divider()
                    Button("Quit ZPaste") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings and More").accessibilityLabel("Settings and More")
            }
            .font(.callout).padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .onAppear { PasteController.shared.rememberFrontmostApplication() }
    }
}

private struct RecentClipButton: View {
    @State private var hovered = false
    let clip: Clip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: ClipboardPresentation.isWebLink(clip.text) ? "link" : "text.alignleft")
                    .foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.text).font(.callout).lineLimit(1).truncationMode(.tail)
                    Text(SourceApplication.info(for: clip.sourceAppBundleID).name)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if clip.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                if hovered { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu { Button("Copy Only") { PasteController.shared.copy(clip.text) } }
    }
}
