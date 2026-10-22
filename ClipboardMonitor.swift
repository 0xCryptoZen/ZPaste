import AppKit
import Foundation
import SwiftData

/// Polls the pasteboard; filtering and self-write suppression happen before reading text.
@MainActor
final class ClipboardMonitor {
    private static var ownWrites = ClipboardWriteSuppression()
    private let pasteboard = NSPasteboard.general
    private let modelContext: ModelContext
    private var lastChangeCount: Int
    private var timer: Timer?
    private var lastCleanup = Date.distantPast
    private var policyObserver: NSObjectProtocol?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        lastChangeCount = NSPasteboard.general.changeCount
    }

    @discardableResult
    static func write(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        let written = board.setString(text, forType: .string)
        ownWrites.recordWrite(changeCount: board.changeCount)
        return written
    }

    func start(interval: TimeInterval = 0.3) {
        stop()
        cleanup()
        policyObserver = NotificationCenter.default.addObserver(
            forName: .historyPolicyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cleanup() }
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let policyObserver { NotificationCenter.default.removeObserver(policyObserver) }
        policyObserver = nil
    }

    private func poll() {
        if Date.now.timeIntervalSince(lastCleanup) >= 60 { cleanup() }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !Self.ownWrites.shouldIgnore(changeCount: count) else { return }

        let defaults = UserDefaults.standard
        guard CapturePolicy.shouldRecord(
            paused: defaults.bool(forKey: "capturePaused"),
            types: Set((pasteboard.types ?? []).map(\.rawValue)),
            ignoreConfidential: defaults.bool(forKey: "ignoreConfidential"),
            ignoreTransient: defaults.bool(forKey: "ignoreTransient")
        ) else { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ignored = defaults.stringArray(forKey: "ignoredBundleIDs") ?? []
        if let source, ignored.contains(source) { return }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try HistoryMaintenance.record(
                text: text, source: source, mergeDuplicates: defaults.bool(forKey: "mergeDuplicates"),
                in: modelContext
            )
            cleanup()
        } catch {
            modelContext.rollback()
            AppStatus.shared.errorMessage = "Could not save clipboard history: \(error.localizedDescription)"
        }
    }

    private func cleanup() {
        lastCleanup = .now
        do {
            try HistoryMaintenance.clean(
                in: modelContext,
                days: UserDefaults.standard.integer(forKey: "retentionDays"),
                limit: UserDefaults.standard.integer(forKey: "historyLimit")
            )
        } catch {
            modelContext.rollback()
            AppStatus.shared.errorMessage = "Could not clean up history: \(error.localizedDescription)"
        }
    }
}
