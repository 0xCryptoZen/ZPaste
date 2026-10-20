import AppKit
import Foundation
import SwiftData

/// 轮询系统剪贴板，把新增的文本历史写入 SwiftData。
/// macOS 没有公开的“剪贴板变化”通知，所以用 changeCount 轮询是标准做法。
@MainActor
final class ClipboardMonitor {
    /// 标记“自己往剪贴板写内容”的变化（例如从历史里点“复制”），避免重复入库。
    static var skipNextChange = false

    private let pasteboard = NSPasteboard.general
    private let modelContext: ModelContext
    private var lastChangeCount: Int
    private var timer: Timer?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start(interval: TimeInterval = 0.3) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // 自己写入剪贴板的变化不重新入库。
        if Self.skipNextChange {
            Self.skipNextChange = false
            return
        }

        // 忽略来自敏感应用（黑名单）的复制内容。
        guard !isFrontmostAppIgnored() else { return }

        guard let text = pasteboard.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 与最近一条去重（避免重复入库）。
        if latestClipText() == text { return }

        let clip = Clip(text: text, sourceAppBundleID: frontmostBundleID)
        modelContext.insert(clip)
        try? modelContext.save()
    }

    private func latestClipText() -> String? {
        var descriptor = FetchDescriptor<Clip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.text
    }

    private var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func isFrontmostAppIgnored() -> Bool {
        guard let id = frontmostBundleID else { return false }
        return ignoredBundleIDs.contains(id)
    }

    /// 从 UserDefaults 读取忽略列表（设置页写入）。
    private var ignoredBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? [])
    }
}
