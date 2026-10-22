import AppKit
import Foundation

/// Only runs while unlocked and recording. Filtering happens before reading text.
@MainActor
final class ClipboardMonitor {
    private static var ownWrites = ClipboardWriteSuppression()
    private static var ownedClipboardCount: Int?
    private let pasteboard = NSPasteboard.general
    private weak var session: VaultSession?
    private var lastChangeCount = 0
    private var lastSource: String?
    private var sourceChanged = false
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    var isRunning: Bool { timer != nil }

    init(session: VaultSession) { self.session = session }

    @discardableResult
    static func write(_ text: String) -> Bool {
        guard VaultSession.shared.isUnlocked else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        let written = board.setString(text, forType: .string)
        ownWrites.recordWrite(changeCount: board.changeCount)
        ownedClipboardCount = written ? board.changeCount : nil
        return written
    }

    static func clearOwnedClipboard() {
        let board = NSPasteboard.general
        if ownedClipboardCount == board.changeCount { board.clearContents() }
        ownedClipboardCount = nil
    }

    func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        lastSource = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sourceChanged = false
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sourceChanged = true }
        }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        captureTask?.cancel(); captureTask = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func poll() {
        guard let session, session.isUnlocked, !UserDefaults.standard.bool(forKey: "capturePaused") else { stop(); return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let unstable = sourceChanged || source != lastSource
        sourceChanged = false; lastSource = source
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !Self.ownWrites.shouldIgnore(changeCount: count), !unstable,
              let source, source != Bundle.main.bundleIdentifier, captureTask == nil else { return }
        let defaults = UserDefaults.standard
        guard CapturePolicy.shouldRecord(
            paused: false, types: Set((pasteboard.types ?? []).map(\.rawValue)),
            ignoreConfidential: defaults.bool(forKey: "ignoreConfidential"),
            ignoreTransient: defaults.bool(forKey: "ignoreTransient")
        ), !(defaults.stringArray(forKey: "ignoredBundleIDs") ?? []).contains(source) else { return }
        guard let text = pasteboard.string(forType: .string),
              pasteboard.changeCount == count,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == source,
              !sourceChanged, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        captureTask = Task { [weak self, weak session] in
            await session?.capture(text, source: source)
            self?.captureTask = nil
        }
    }
}
