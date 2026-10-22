import AppKit
import Combine
import CryptoKit

@MainActor
final class VaultSession: ObservableObject {
    enum State { case locked, unlocking, ready, failed }
    static let shared = VaultSession()
    @Published private(set) var state: State = .locked
    @Published private(set) var revision = UUID()
    @Published private(set) var summary = VaultSummary()
    @Published private(set) var recent: [ClipItem] = []
    @Published private(set) var errorMessage: String?
    private(set) var repository: VaultRepository?
    private var lease: VaultLease?
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var refreshing = false
    private var needsRefresh = false
    private var deleting = false
    private let keychain = VaultKeychain()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var monitor = ClipboardMonitor(session: self)
    var isUnlocked: Bool { state == .ready }
    var retention: RetentionSettings {
        RetentionSettings(days: UserDefaults.standard.integer(forKey: "retentionDays"),
                          limit: UserDefaults.standard.integer(forKey: "historyLimit"),
                          enabled: !UserDefaults.standard.bool(forKey: "legacyPolicyPending"))
    }

    private init() {
        do { repository = VaultRepository(paths: try StorePaths.standard(), memoryOnly: UIPreviewData.enabled) }
        catch { errorMessage = VaultError.storage.localizedDescription; state = .failed }
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.lock() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.lock() }
        observe(NotificationCenter.default, UserDefaults.didChangeNotification) { $0.updateMonitoring() }
        observe(NotificationCenter.default, .historyPolicyChanged) { $0.cleanup() }
        if UIPreviewData.enabled { unlock() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping (VaultSession) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func stop() {
        lock()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    func unlock() {
        guard state != .unlocking, !isUnlocked, let repository else { return }
        state = .unlocking; errorMessage = nil
        generation = UUID()
        let epoch = generation
        let lease = VaultLease()
        self.lease = lease
        operation = Task { [weak self, keychain] in
            do {
                let existing = await repository.requiresExistingKey()
                let key: SymmetricKey
                if UIPreviewData.enabled { key = SymmetricKey(size: .bits256) }
                else {
                    key = try await Task.detached { try keychain.load(createIfMissing: !existing, reason: "Unlock your encrypted clipboard history") }.value
                }
                try lease.check()
                let migrated = try await repository.unlock(key: key, lease: lease)
                if UIPreviewData.enabled { try await UIPreviewData.populate(repository) }
                try lease.check()
                guard let self, self.generation == epoch else { return }
                if migrated { UserDefaults.standard.set(true, forKey: "legacyPolicyPending") }
                self.state = .ready
                await self.refresh()
                guard self.generation == epoch, self.isUnlocked else { return }
                self.updateMonitoring()
                self.maintenance = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        guard let self, self.isUnlocked, self.generation == epoch else { return }
                        self.cleanup()
                    }
                }
            } catch {
                guard let self, self.generation == epoch else { return }
                self.fail(error)
            }
        }
    }

    func lock() {
        lease?.invalidate(); lease = nil
        keychain.cancel()
        operation?.cancel(); operation = nil
        maintenance?.cancel(); maintenance = nil
        generation = UUID(); revision = UUID()
        state = .locked; deleting = false
        monitor.stop()
        PasteController.shared.cancelDelivery()
        ClipboardMonitor.clearOwnedClipboard()
        recent = []; summary = VaultSummary(); errorMessage = nil
        AppStatus.shared.clear()
        SourceApplication.clear()
        if let repository { Task { await repository.lock() } }
    }

    func fail(_ error: Error) {
        let message = (error as? VaultError)?.localizedDescription ?? VaultError.storage.localizedDescription
        lock()
        errorMessage = message; state = .failed
    }

    func updateMonitoring() {
        guard isUnlocked, !UIPreviewData.enabled, !UserDefaults.standard.bool(forKey: "capturePaused") else { monitor.stop(); return }
        if !monitor.isRunning { monitor.start() }
    }

    func capture(_ text: String, source: String) async {
        guard isUnlocked, let repository else { return }
        let epoch = generation
        do {
            try await repository.record(text: text, source: source, merge: UserDefaults.standard.bool(forKey: "mergeDuplicates"), retention: retention)
            guard epoch == generation, isUnlocked else { return }
            await refresh()
        } catch VaultError.tooLarge { if epoch == generation { AppStatus.shared.errorMessage = VaultError.tooLarge.localizedDescription } }
        catch VaultError.capacity {
            guard epoch == generation, isUnlocked else { return }
            UserDefaults.standard.set(true, forKey: "capturePaused")
            updateMonitoring()
            AppStatus.shared.errorMessage = VaultError.capacity.localizedDescription
        } catch { if epoch == generation { fail(error) } }
    }

    func refresh() async {
        guard isUnlocked, let repository else { return }
        if refreshing { needsRefresh = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            needsRefresh = false
            let epoch = generation
            do {
                let summary = try await repository.summary()
                let recent = try await repository.page(scope: .all, search: "", limit: 8, byteLimit: VaultLimits.payloadBytes / 4, recent: true)
                guard epoch == generation, isUnlocked else { return }
                self.summary = summary; self.recent = recent.clips
                revision = UUID()
            } catch { if epoch == generation { fail(error) }; return }
        } while needsRefresh && isUnlocked
    }

    func mutate(_ action: @escaping @Sendable (VaultRepository) async throws -> Void) async -> Bool {
        guard isUnlocked, let repository else { return false }
        let epoch = generation
        do {
            try await action(repository)
            guard epoch == generation, isUnlocked else { return false }
            await refresh()
            return isUnlocked
        } catch VaultError.pinLimit { AppStatus.shared.errorMessage = VaultError.pinLimit.localizedDescription }
        catch VaultError.tooLarge { AppStatus.shared.errorMessage = VaultError.tooLarge.localizedDescription }
        catch VaultError.capacity { AppStatus.shared.errorMessage = VaultError.capacity.localizedDescription }
        catch VaultError.missingRecord { AppStatus.shared.errorMessage = VaultError.missingRecord.localizedDescription }
        catch { if epoch == generation { fail(error) } }
        return false
    }

    func cleanup() {
        guard isUnlocked else { return }
        let policy = retention
        Task { _ = await mutate { try await $0.clean(retention: policy) } }
    }

    func deleteEverything() {
        guard isUnlocked, !deleting, let repository else { return }
        deleting = true
        let epoch = generation
        operation = Task { [weak self, keychain] in
            do {
                _ = try await Task.detached { try keychain.load(createIfMissing: false, reason: "Delete all clipboard history, including pins and folders") }.value
                guard let self, epoch == self.generation, self.isUnlocked else { return }
                try await repository.clear(includePinned: true)
                guard epoch == self.generation else { return }
                self.lock()
            } catch { if let self, epoch == self.generation { self.fail(error) } }
        }
    }

    func clearError() { errorMessage = nil; AppStatus.shared.errorMessage = nil }

    func use(_ id: UUID, copyOnly: Bool = false, forcePaste: Bool = false) {
        guard isUnlocked, let repository else { return }
        let epoch = generation
        Task {
            do {
                let text = try await repository.text(id)
                guard epoch == generation, isUnlocked, !Task.isCancelled else { return }
                if copyOnly { PasteController.shared.copy(text) }
                else { PasteController.shared.select(text, forcePaste: forcePaste) }
            } catch { if epoch == generation { fail(error) } }
        }
    }
}
