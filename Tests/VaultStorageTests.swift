import Foundation
import CryptoKit
import SwiftData

/// Simulates a storage/process failure immediately after a durable batch save.
final class SaveFailure: @unchecked Sendable {
    private let mutex = NSLock()
    private var remaining = 0
    func arm(after saves: Int) { mutex.lock(); remaining = saves; mutex.unlock() }
    func checkpoint() throws {
        mutex.lock()
        let fail = remaining == 1
        if remaining > 0 { remaining -= 1 }
        mutex.unlock()
        if fail { throw VaultError.storage }
    }
}

@main
struct VaultStorageTests {
    static func expectFailure(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("An unsafe operation succeeded") } catch { }
    }

    @MainActor
    static func legacyFixture(at url: URL) throws {
        let schema = Schema([Clip.self, Folder.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let folder = Folder(name: "private-folder-marker")
        context.insert(folder)
        for index in 0..<230 {
            context.insert(Clip(text: "private-body-marker-\(index)", createdAt: Date(timeIntervalSince1970: Double(index)),
                                isPinned: index == 0, sourceAppBundleID: "private-source-marker", folder: folder))
        }
        try context.save()
    }

    static func scan(_ directory: URL) throws {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in files {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let data = try Data(contentsOf: url)
                for marker in ["private-body-marker", "private-source-marker", "private-folder-marker"] {
                    precondition(data.range(of: Data(marker.utf8)) == nil, "Plaintext leaked into \(url.lastPathComponent)")
                }
            }
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StorePaths(directory: root.appendingPathComponent("vault"), legacy: root.appendingPathComponent("legacy.store"))
        try await legacyFixture(at: paths.legacy)
        let key = SymmetricKey(size: .bits256)
        let repository = VaultRepository(paths: paths)
        await expectFailure { _ = try await repository.page(scope: .all, search: "") }
        var lease = VaultLease()
        let migrated = try await repository.unlock(key: key, lease: lease)
        precondition(migrated && !FileManager.default.fileExists(atPath: paths.legacy.path))
        let summary = try await repository.summary()
        precondition(summary.count == 230 && summary.pinned == 1 && summary.folders.first?.count == 230)
        let first = try await repository.page(scope: .all, search: "")
        precondition(first.clips.count == 100 && first.clips.first?.isPinned == true)
        let next = try await repository.page(scope: .all, search: "", offset: first.nextOffset!)
        precondition(next.clips.count == 100 && Set(first.clips.map(\.id)).isDisjoint(with: next.clips.map(\.id)))
        let matching = try await repository.page(scope: .all, search: "private-body-marker-229")
        precondition(matching.clips.count == 1)
        let existing = first.clips[0]
        try await repository.record(text: existing.text, source: "private-source-marker", merge: true,
                                    retention: RetentionSettings(days: 0, limit: 0, enabled: false))
        let merged = try await repository.summary()
        precondition(merged.count == 230 && merged.pinned == 1)
        try await repository.delete(summary.folders[0].id)
        var position: Int? = 0
        var checked = 0
        while let offset = position {
            let withoutFolder = try await repository.page(scope: .all, search: "", offset: offset)
            precondition(withoutFolder.clips.allSatisfy { $0.folderID == nil })
            checked += withoutFolder.clips.count
            position = withoutFolder.nextOffset
        }
        precondition(checked == 230)
        lease.invalidate(); await repository.lock(); lease = VaultLease()
        _ = try await repository.unlock(key: key, lease: lease)
        try await repository.clean(retention: .safe)
        let cleaned = try await repository.summary()
        precondition(cleaned.count == 1 && cleaned.pinned == 1)
        try scan(paths.directory)
        lease.invalidate()
        await expectFailure { _ = try await repository.page(scope: .all, search: "") }
        await expectFailure { try await repository.record(text: "late copy", source: "test", merge: false, retention: .safe) }
        await repository.lock()
        await expectFailure { _ = try await repository.unlock(key: SymmetricKey(size: .bits256), lease: VaultLease()) }
        precondition(FileManager.default.fileExists(atPath: paths.database.path))
        let migratedAgain = try await repository.unlock(key: key, lease: VaultLease())
        precondition(!migratedAgain)
        try await repository.clear(includePinned: true)
        let empty = try await repository.summary()
        precondition(empty.count == 0 && empty.folders.isEmpty)
        await repository.lock()
        // A missing base file must not hide leftover plaintext migration sidecars.
        try paths.mark(paths.pending)
        let oldWAL = paths.sidecars(paths.legacy)[0]
        try Data("private-body-marker orphan WAL".utf8).write(to: oldWAL)
        _ = try await repository.unlock(key: key, lease: VaultLease())
        precondition(!FileManager.default.fileExists(atPath: oldWAL.path))
        precondition(!FileManager.default.fileExists(atPath: paths.pending.path))
        await repository.lock()

        // Interrupt migration after a durable folder batch; the original must survive for retry.
        let interrupted = StorePaths(directory: root.appendingPathComponent("interrupted"), legacy: root.appendingPathComponent("retry.store"))
        try await legacyFixture(at: interrupted.legacy)
        let failure = SaveFailure()
        let retry = VaultRepository(paths: interrupted, saveCheckpoint: { try failure.checkpoint() })
        failure.arm(after: 2)
        await expectFailure { _ = try await retry.unlock(key: key, lease: VaultLease()) }
        precondition(FileManager.default.fileExists(atPath: interrupted.legacy.path))
        precondition(!FileManager.default.fileExists(atPath: interrupted.committed.path))
        _ = try await retry.unlock(key: key, lease: VaultLease())
        let recovered = try await retry.summary()
        precondition(recovered.count == 230 && recovered.folders[0].count == 230)
        // Delete ALL may stop after any committed batch without orphaning a folder relationship.
        failure.arm(after: 1)
        await expectFailure { try await retry.clear(includePinned: true) }
        await retry.lock()
        _ = try await retry.unlock(key: key, lease: VaultLease())
        let partial = try await retry.summary()
        precondition(partial.count == 130 && partial.folders.count == 1 && partial.folders[0].count == 130)
        try await retry.clear(includePinned: true)
        await retry.lock()

        // An unrecognized old database must remain byte-for-byte unchanged, with no commit marker.
        let invalid = StorePaths(directory: root.appendingPathComponent("invalid"), legacy: root.appendingPathComponent("unknown.store"))
        let old = Data("not a known database".utf8)
        try old.write(to: invalid.legacy)
        let broken = VaultRepository(paths: invalid)
        await expectFailure { _ = try await broken.unlock(key: key, lease: VaultLease()) }
        let unchanged = try Data(contentsOf: invalid.legacy)
        precondition(unchanged == old && !FileManager.default.fileExists(atPath: invalid.committed.path))
        print("Vault storage tests passed: migration, round trips, paging, search, dedup, folder preservation, retention, plaintext scan, lock rejection, wrong key, restart, and unknown-store preservation")
    }
}
