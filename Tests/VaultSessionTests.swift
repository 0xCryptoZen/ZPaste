import Foundation
import CryptoKit
import AppKit

final class TestKeyProvider: VaultKeyProviding, @unchecked Sendable {
    let key = SymmetricKey(size: .bits256)
    private let mutex = NSLock()
    private var shouldFail = false
    private var block = false
    private var entered = false
    let proceed = DispatchSemaphore(value: 0)
    var hasEntered: Bool { mutex.lock(); defer { mutex.unlock() }; return entered }
    func configure(fail: Bool = false, block: Bool = false) {
        while proceed.wait(timeout: .now()) == .success { }
        mutex.lock(); shouldFail = fail; self.block = block; entered = false; mutex.unlock()
    }
    func cancel() { proceed.signal() }
    func load(createIfMissing: Bool, reason: String, lease: VaultLease) throws -> SymmetricKey {
        try lease.check()
        mutex.lock(); let failure = shouldFail; let blocked = block; entered = true; mutex.unlock()
        if blocked { _ = proceed.wait(timeout: .now() + 5) }
        if failure { throw VaultError.keychain(-1) }
        return key
    }
}

@main
struct VaultSessionTests {
    @MainActor
    static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Session did not reach the expected state")
    }

    @MainActor
    static func main() async throws {
        // No real Keychain access, clipboard monitoring, or clipboard writes in these tests.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = VaultRepository(paths: StorePaths(directory: root, legacy: root.appendingPathComponent("old.store")), memoryOnly: true)
        let provider = TestKeyProvider()
        let session = VaultSession(repository: repository, keyProvider: provider, captureAllowed: false, preview: false)
        precondition(!session.isUnlocked)
        session.unlock(); session.lock()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!provider.hasEntered, "Cancelled unlock launched a late authentication request")
        provider.configure(fail: true)
        session.unlock()
        await wait { session.state == .failed }
        precondition(session.recent.isEmpty && session.summary.count == 0)
        provider.configure()
        session.unlock()
        await wait { session.isUnlocked }
        await session.capture("session-private-marker", source: "test")
        await wait { session.summary.count == 1 }
        precondition(session.summary.count == 1 && session.recent.count == 1)
        let pendingMutation = Task {
            await session.mutate { repository in
                try await Task.sleep(for: .milliseconds(100))
                try await repository.record(text: "stale mutation", source: "test", merge: false, retention: .safe)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        session.lock()
        precondition(!session.isUnlocked && session.recent.isEmpty && session.summary.folders.isEmpty)
        await session.capture("copy after lock", source: "test")
        precondition(session.recent.isEmpty)
        session.unlock()
        await wait { session.isUnlocked }
        let applied = await pendingMutation.value
        precondition(!applied)
        let newSummary = try await repository.summary()
        precondition(newSummary.count == 0, "An old task borrowed the new unlock's key")
        session.lock()

        // A key read that finishes after cancellation cannot unlock or publish data.
        provider.configure(block: true)
        session.unlock()
        await wait { provider.hasEntered }
        session.lock()
        provider.proceed.signal()
        try await Task.sleep(for: .milliseconds(100))
        precondition(session.state == .locked && session.recent.isEmpty)

        // A delayed lock for a previous lease must not clear a newer repository session.
        let oldLease = VaultLease()
        _ = try await repository.unlock(key: provider.key, lease: oldLease)
        oldLease.invalidate()
        let newLease = VaultLease()
        _ = try await repository.unlock(key: provider.key, lease: newLease)
        await repository.lock(lease: oldLease)
        _ = try await repository.summary()
        do {
            _ = try await VaultAccess.$lease.withValue(oldLease) { try await repository.summary() }
            preconditionFailure("Old operations must not borrow a new session")
        } catch VaultError.locked { }
        newLease.invalidate()
        session.stop()
        print("Vault session tests passed: authentication denial, unlock, memory clearing, post-lock capture rejection, late authentication, and old-lease isolation")
    }
}
