import AppKit
import SwiftUI
import SwiftData

/// 菜单栏下拉面板：最近几条 + 打开历史 + 退出。
struct MenuBarView: View {
    @Query(sort: \Clip.createdAt, order: .reverse) private var recentClips: [Clip]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                NotificationCenter.default.post(name: .showHistoryWindow, object: nil)
            } label: {
                Label("打开历史", systemImage: "clock")
            }

            Divider()

            if recentClips.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                Text("最近").font(.caption).foregroundStyle(.secondary)
                ForEach(recentClips.prefix(10)) { clip in
                    Button {
                        copy(clip.text)
                    } label: {
                        Text(clip.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 340)
    }

    private func copy(_ text: String) {
        ClipboardMonitor.skipNextChange = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
