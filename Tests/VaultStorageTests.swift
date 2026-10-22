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

extension VaultRepository {
    func corruptCachedPayloadForTest(_ id: UUID) throws {
        let record = try find(id)
        record.sealedPayload[record.sealedPayload.count - 1] ^= 1
        try save()
    }
}

@main
struct VaultStorageTests {
    static func stage(_ message: String) { FileHandle.standardError.write(Data("VAULT TEST: \(message)\n".utf8)) }
    static func expectFailure(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("An unsafe operation succeeded") } catch { }
    }

    @MainActor
    static func legacyFixture(at url: URL, count: Int = 230, textBytes: Int = 0) throws {
        let schema = Schema([Clip.self, Folder.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let folder = Folder(name: "private-folder-marker")
        context.insert(folder)
        for index in 0..<count {
            let text = String(repeating: "x", count: textBytes) + "private-body-marker-\(index)"
            context.insert(Clip(text: text, createdAt: Date(timeIntervalSince1970: Double(index)),
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
        stage("starting")
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
        stage("initial migration complete")
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
        stage("folder removed; checking every page")
        var position: Int? = 0
        var checked = 0
        while let offset = position {
            let withoutFolder = try await repository.page(scope: .all, search: "", offset: offset)
            precondition(withoutFolder.clips.allSatisfy { $0.folderID == nil })
            checked += withoutFolder.clips.count
            position = withoutFolder.nextOffset
        }
        precondition(checked == 230)
        stage("all folder pages checked")
        lease.invalidate(); await repository.lock(); lease = VaultLease()
        _ = try await repository.unlock(key: key, lease: lease)
        try await repository.clean(retention: .safe)
        let cleaned = try await repository.summary()
        precondition(cleaned.count == 1 && cleaned.pinned == 1)
        stage("retention complete")
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
        stage("empty restart and orphaned WAL")
        try paths.mark(paths.pending)
        let oldWAL = paths.sidecars(paths.legacy)[0]
        try Data("private-body-marker orphan WAL".utf8).write(to: oldWAL)
        _ = try await repository.unlock(key: key, lease: VaultLease())
        precondition(!FileManager.default.fileExists(atPath: oldWAL.path))
        precondition(!FileManager.default.fileExists(atPath: paths.pending.path))
        await repository.lock()

        // Interrupt migration after a durable folder batch; the original must survive for retry.
        stage("interrupted migration")
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
        stage("migration retry complete")
        precondition(recovered.count == 230 && recovered.folders[0].count == 230)
        // Delete ALL may stop after any committed batch without orphaning a folder relationship.
        failure.arm(after: 1)
        await expectFailure { try await retry.clear(includePinned: true) }
        await retry.lock()
        stage("interrupted deletion complete")
        _ = try await retry.unlock(key: key, lease: VaultLease())
        let partial = try await retry.summary()
        precondition(partial.count == 130 && partial.folders.count == 1 && partial.folders[0].count == 130)
        try await retry.clear(includePinned: true)
        await retry.lock()

        // Grandfathered oversized history must migrate intact, with bounded display previews.
        stage("oversized legacy history")
        let largePaths = StorePaths(directory: root.appendingPathComponent("large"), legacy: root.appendingPathComponent("large-old.store"))
        try await legacyFixture(at: largePaths.legacy, count: 2, textBytes: 11 * 1024 * 1024)
        let large = VaultRepository(paths: largePaths)
        _ = try await large.unlock(key: key, lease: VaultLease())
        let largeSummary = try await large.summary()
        precondition(largeSummary.count == 2 && largeSummary.payloadBytes > VaultLimits.payloadBytes)
        let previews = try await large.page(scope: .all, search: "")
        precondition(previews.clips.count == 2 && previews.clips.allSatisfy { $0.isPreviewOnly && $0.text.utf8.count <= 2_048 })
        let whole = try await large.text(previews.clips[0].id)
        precondition(whole.utf8.count > 11 * 1024 * 1024)
        await expectFailure { try await large.record(text: "new copy", source: "test", merge: false, retention: .safe) }
        let retained = try await large.summary()
        precondition(retained.count == 2)
        await large.lock()

        let pins = VaultRepository(paths: paths, memoryOnly: true)
        stage("pin limit")
        _ = try await pins.unlock(key: key, lease: VaultLease())
        let noCleanup = RetentionSettings(days: 0, limit: 0, enabled: false)
        for index in 0..<101 { try await pins.record(text: "pin-\(index)", source: "test", merge: false, retention: noCleanup) }
        let pinPage = try await pins.page(scope: .all, search: "", limit: 101)
        for clip in pinPage.clips.prefix(100) { try await pins.changeClip(clip.id, pinned: true) }
        await expectFailure { try await pins.changeClip(pinPage.clips[100].id, pinned: true) }
        let pinSummary = try await pins.summary()
        precondition(pinSummary.pinned == 100)
        let cachedID = pinPage.clips[0].id
        _ = try await pins.text(cachedID)
        try await pins.corruptCachedPayloadForTest(cachedID)
        await expectFailure { _ = try await pins.text(cachedID) }
        await pins.lock()

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
