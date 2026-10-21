import AppKit
import Foundation
import SwiftData

/// Polls the system pasteboard and writes new text entries into SwiftData.
/// macOS exposes no public clipboard-changed notification, so polling
/// `changeCount` is the standard approach.
@MainActor
final class ClipboardMonitor {
    /// Flags changes caused by our own writes to the pasteboard (e.g. clicking
    /// "Copy" in history), so they are not re-captured.
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

        // Don't re-capture changes we wrote ourselves.
        if Self.skipNextChange {
            Self.skipNextChange = false
            return
        }

        // Ignore content copied from ignored (sensitive) apps.
        guard !isFrontmostAppIgnored() else { return }

        guard let text = pasteboard.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Deduplicate against the latest entry.
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

    /// Reads the ignore list from UserDefaults (written by the settings view).
    private var ignoredBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? [])
    }
}