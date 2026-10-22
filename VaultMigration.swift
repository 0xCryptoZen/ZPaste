import Foundation
import SwiftData
import CryptoKit

extension VaultRepository {
    /// Opens only the exact historical default URL, without CloudKit or save permission.
    func migrateLegacy() throws {
        do {
            try paths.requireRegularFile(paths.legacy)
            for file in paths.sidecars(paths.legacy) where FileManager.default.fileExists(atPath: file.path) {
                try paths.requireRegularFile(file)
            }
            let schema = Schema([Clip.self, Folder.self])
            let config = ModelConfiguration(schema: schema, url: paths.legacy, allowsSave: false, cloudKitDatabase: .none)
            let legacyContainer = try ModelContainer(for: schema, configurations: [config])
            let legacy = ModelContext(legacyContainer)
            legacy.autosaveEnabled = false
            let expectedClips = try legacy.fetchCount(FetchDescriptor<Clip>())
            let expectedFolders = try legacy.fetchCount(FetchDescriptor<Folder>())
            var folderIDs: [PersistentIdentifier: UUID] = [:]
            var folderRequest = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\Folder.createdAt), SortDescriptor(\Folder.name)])
            folderRequest.fetchLimit = VaultLimits.pageSize
            folderRequest.fetchOffset = 0
            while true {
                try checkLease()
                let folders = try legacy.fetch(folderRequest)
                if folders.isEmpty { break }
                for folder in folders {
                    let id = UUID()
                    folderIDs[folder.persistentModelID] = id
                    let metadata = RecordMetadata(id: id, kind: .folder, createdAt: folder.createdAt, isPinned: false, folderID: nil)
                    try importVerified(metadata, value: RecordPayload(text: folder.name, source: nil))
                }
                try save()
                folderRequest.fetchOffset = (folderRequest.fetchOffset ?? 0) + folders.count
            }
            var clipRequest = FetchDescriptor<Clip>(sortBy: [SortDescriptor(\Clip.createdAt), SortDescriptor(\Clip.text)])
            clipRequest.fetchLimit = VaultLimits.pageSize
            clipRequest.fetchOffset = 0
            while true {
                try checkLease()
                let clips = try legacy.fetch(clipRequest)
                if clips.isEmpty { break }
                for clip in clips {
                    let folder = clip.folder.flatMap { folderIDs[$0.persistentModelID] }
                    if clip.folder != nil && folder == nil { throw VaultError.migration }
                    let metadata = RecordMetadata(id: UUID(), kind: .clip, createdAt: clip.createdAt, isPinned: clip.isPinned, folderID: folder)
                    try importVerified(metadata, value: RecordPayload(text: clip.text, source: clip.sourceAppBundleID))
                }
                try save()
                clipRequest.fetchOffset = (clipRequest.fetchOffset ?? 0) + clips.count
            }
            let (destination, _) = try access()
            let actualClips = try destination.fetchCount(request())
            let actualFolders = try destination.fetchCount(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "folder" }))
            guard actualClips == expectedClips, actualFolders == expectedFolders,
                  expectedClips == (try legacy.fetchCount(FetchDescriptor<Clip>())),
                  expectedFolders == (try legacy.fetchCount(FetchDescriptor<Folder>())) else { throw VaultError.migration }
        } catch VaultError.locked { throw VaultError.locked }
        catch { throw VaultError.migration }
    }

    private func importVerified(_ metadata: RecordMetadata, value: RecordPayload) throws {
        try checkLease()
        try write(metadata, payload: value)
        let record = try find(metadata.id)
        let actualMetadata = try record.metadata()
        let actualPayload = try payload(record)
        guard actualMetadata == metadata, actualPayload == value else { throw VaultError.migration }
    }

    /// Includes every byte and all authenticated metadata, ordered by stable record ID.
    func durableProof() throws -> Data {
        var digest = SHA256()
        var count: UInt64 = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try batches(FetchDescriptor<VaultRecord>(sortBy: [SortDescriptor(\VaultRecord.orderID)])) { record in
            digest.update(data: try encoder.encode(record.metadata()))
            digest.update(data: record.sealedPayload)
            count += 1
        }
        withUnsafeBytes(of: count.bigEndian) { digest.update(bufferPointer: $0) }
        return Data(digest.finalize())
    }
}
