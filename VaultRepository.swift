import Foundation
import SwiftData
import CryptoKit

/// Contexts, keys and persistent models stay on this serial executor.
actor VaultRepository {
    private var container: ModelContainer?
    private var context: ModelContext?
    private var key: SymmetricKey?
    private var lease: VaultLease?
    private var payloadByteCount: Int?
    private var duplicateKey = SymmetricKey(size: .bits256)
    private var duplicates: [Data: (id: UUID, date: Date)] = [:]
    private var fingerprints: [UUID: Data] = [:]
    private var indexComplete = true
    private struct CachedPayload {
        let metadata: RecordMetadata
        let sealed: Data
        let payload: RecordPayload
        let bytes: Int
    }
    private var decoded: [UUID: CachedPayload] = [:]
    private var decodedBytes = 0
    private static let headerID = UUID(uuidString: "861CB4AD-9C39-4E4F-9087-7552646E1D12")!
    let paths: StorePaths
    private let memoryOnly: Bool
    private let saveCheckpoint: (@Sendable () throws -> Void)?

    init(paths: StorePaths, memoryOnly: Bool = false, saveCheckpoint: (@Sendable () throws -> Void)? = nil) {
        self.paths = paths; self.memoryOnly = memoryOnly; self.saveCheckpoint = saveCheckpoint
    }
    func requiresExistingKey() -> Bool { !memoryOnly && paths.requiresExistingKey }

    func unlock(key: SymmetricKey, lease: VaultLease) throws -> Bool {
        try lease.check()
        // Never authenticate a new key using payloads cached under a previous unlock.
        lock()
        self.key = key; self.lease = lease
        do {
            if memoryOnly {
                let schema = Schema([VaultRecord.self])
                container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                context = ModelContext(container!)
                context?.autosaveEnabled = false
                try createHeader()
                return false
            }
            try paths.prepare()
            let fm = FileManager.default
            let isCommitted = fm.fileExists(atPath: paths.committed.path)
            if !isCommitted {
                if fm.fileExists(atPath: paths.database.path) {
                    guard fm.fileExists(atPath: paths.pending.path) else { throw VaultError.migration }
                    try paths.removeDatabase(paths.database)
                }
                try paths.mark(paths.pending)
            } else {
                guard fm.fileExists(atPath: paths.database.path) else { throw VaultError.storage }
            }
            try openStore()
            if !isCommitted { try createHeader() }
            let hadLegacy = !isCommitted && fm.fileExists(atPath: paths.legacy.path)
            if hadLegacy { try migrateLegacy() }
            try validateAll()
            if !isCommitted {
                let expectedProof = try durableProof()
                context = nil; container = nil
                try openStore()
                try validateAll()
                guard try durableProof() == expectedProof else { throw VaultError.migration }
                try lease.check()
                try paths.mark(paths.committed)
            }
            if fm.fileExists(atPath: paths.pending.path) {
                try paths.removeDatabase(paths.legacy)
                try fm.removeItem(at: paths.pending)
            }
            return hadLegacy
        } catch {
            context?.rollback(); lock()
            throw error
        }
    }

    func lock(lease expected: VaultLease? = nil) {
        if let expected, lease !== expected { return }
        lease?.invalidate()
        key = nil; lease = nil; context = nil; container = nil; payloadByteCount = nil
        duplicates.removeAll(); fingerprints.removeAll(); duplicateKey = SymmetricKey(size: .bits256); indexComplete = true
        decoded.removeAll(); decodedBytes = 0
    }

    private func openStore() throws {
        let schema = Schema([VaultRecord.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: paths.database, cloudKitDatabase: .none)])
        context = ModelContext(container!)
        context?.autosaveEnabled = false
        try paths.protectFiles()
    }

    func access() throws -> (ModelContext, SymmetricKey) {
        try lease?.check()
        if let expected = VaultAccess.lease, lease !== expected { throw VaultError.locked }
        guard let context, let key, lease != nil else { throw VaultError.locked }
        return (context, key)
    }

    func checkLease() throws { _ = try access() }

    func payload(_ record: VaultRecord) throws -> RecordPayload {
        let (_, key) = try access()
        let metadata = try record.metadata()
        let sealed = record.sealedPayload
        if let cached = decoded[metadata.id], cached.metadata == metadata, cached.sealed == sealed { return cached.payload }
        let value = try VaultCipher.open(sealed, metadata: metadata, key: key)
        cache(value, metadata: metadata, sealed: sealed)
        return value
    }

    func write(_ metadata: RecordMetadata, payload: RecordPayload, existing: VaultRecord? = nil) throws {
        let (context, key) = try access()
        let sealed = try VaultCipher.seal(payload, metadata: metadata, key: key)
        if let bytes = payloadByteCount { payloadByteCount = bytes - (existing?.sealedPayload.count ?? 0) + sealed.count }
        if let existing {
            existing.createdAt = metadata.createdAt; existing.isPinned = metadata.isPinned
            existing.pinRank = metadata.isPinned ? 1 : 0
            existing.folderID = metadata.folderID; existing.sealedPayload = sealed
        } else { context.insert(VaultRecord(metadata: metadata, sealedPayload: sealed)) }
        cache(payload, metadata: metadata, sealed: sealed)
        if metadata.kind == .clip { index(metadata, text: payload.text) }
    }

    func save() throws {
        let (context, _) = try access()
        do {
            try context.save()
            if !memoryOnly { try paths.protectFiles() }
            try saveCheckpoint?()
        } catch { context.rollback(); throw VaultError.storage }
    }

    func request(scope: HistoryScope = .all) -> FetchDescriptor<VaultRecord> {
        let predicate: Predicate<VaultRecord>
        switch scope {
        case .all: predicate = #Predicate { $0.kind == "clip" }
        case .pinned: predicate = #Predicate { $0.kind == "clip" && $0.isPinned }
        case .folder(let id): predicate = #Predicate { $0.kind == "clip" && $0.folderID == id }
        }
        return FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\VaultRecord.pinRank, order: .reverse), SortDescriptor(\VaultRecord.createdAt, order: .reverse), SortDescriptor(\VaultRecord.orderID)])
    }

    func batches(_ descriptor: FetchDescriptor<VaultRecord>, visit: (VaultRecord) throws -> Void) throws {
        let (context, _) = try access()
        var descriptor = descriptor
        descriptor.fetchLimit = VaultLimits.pageSize
        descriptor.fetchOffset = 0
        while true {
            try checkLease()
            let records = try context.fetch(descriptor)
            if records.isEmpty { break }
            for record in records { try checkLease(); try visit(record) }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + records.count
        }
    }

    private func validateAll() throws {
        let (context, _) = try access()
        payloadByteCount = 0; duplicates.removeAll(); fingerprints.removeAll(); indexComplete = true
        var headerCount = 0
        try batches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "header" })) { record in
            guard record.id == Self.headerID, !record.isPinned, record.folderID == nil,
                  try payload(record) == RecordPayload(text: "ZPaste encrypted history v1", source: nil) else { throw VaultError.corrupt }
            payloadByteCount? += record.sealedPayload.count
            headerCount += 1
        }
        guard headerCount == 1 else { throw VaultError.corrupt }
        var folders = Set<UUID>()
        try batches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "folder" })) { record in
            _ = try payload(record)
            payloadByteCount? += record.sealedPayload.count
            guard record.folderID == nil, !record.isPinned else { throw VaultError.corrupt }
            folders.insert(record.id)
        }
        try batches(request()) { record in
            let value = try payload(record)
            payloadByteCount? += record.sealedPayload.count
            index(try record.metadata(), text: value.text)
            if let folder = record.folderID, !folders.contains(folder) { throw VaultError.corrupt }
        }
        let known = try context.fetchCount(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "clip" || $0.kind == "folder" || $0.kind == "header" }))
        guard known == (try context.fetchCount(FetchDescriptor<VaultRecord>())) else { throw VaultError.corrupt }
    }

    func page(scope: HistoryScope, search: String, offset: Int = 0, limit: Int = VaultLimits.pageSize,
              byteLimit: Int = VaultLimits.historyDisplayBytes, recent: Bool = false) throws -> VaultPage {
        let (context, _) = try access()
        var descriptor = request(scope: scope)
        if recent { descriptor.sortBy = [SortDescriptor(\VaultRecord.createdAt, order: .reverse), SortDescriptor(\VaultRecord.orderID)] }
        // Small stores can be sorted once without pulling a large legacy store into memory.
        let smallStore = (payloadByteCount ?? Int.max) <= VaultLimits.decryptedCacheBytes
        descriptor.fetchLimit = search.isEmpty ? min(limit, VaultLimits.pageSize) : (smallStore ? 1_000 : VaultLimits.pageSize)
        descriptor.includePendingChanges = false
        descriptor.fetchOffset = offset
        var page = VaultPage()
        var bytes = 0
        while true {
            try checkLease()
            let records = try context.fetch(descriptor)
            if records.isEmpty { return page }
            for (index, record) in records.enumerated() {
                try checkLease()
                let value = try payload(record)
                guard search.isEmpty || value.text.localizedCaseInsensitiveContains(search) else { continue }
                let source = value.source.map { VaultLimits.displayPrefix($0, bytes: 256) }
                let oversized = value.text.utf8.count > byteLimit - (source?.utf8.count ?? 0)
                let displayed = oversized ? VaultLimits.displayPrefix(value.text, bytes: min(2_048, max(byteLimit - 256, 0))) : value.text
                let size = displayed.utf8.count + (source?.utf8.count ?? 0)
                guard bytes + size <= byteLimit else {
                    page.nextOffset = (descriptor.fetchOffset ?? 0) + index
                    return page
                }
                bytes += size
                page.clips.append(ClipItem(id: record.id, text: displayed, createdAt: record.createdAt,
                                          isPinned: record.isPinned, sourceAppBundleID: source, folderID: record.folderID,
                                          isPreviewOnly: oversized))
                if page.clips.count == limit {
                    page.nextOffset = (descriptor.fetchOffset ?? 0) + index + 1
                    return page
                }
            }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + records.count
        }
    }

    func summary() throws -> VaultSummary {
        let (context, _) = try access()
        var result = VaultSummary()
        result.count = try context.fetchCount(request())
        result.pinned = try context.fetchCount(request(scope: .pinned))
        if let payloadByteCount { result.payloadBytes = payloadByteCount }
        else {
            try batches(FetchDescriptor<VaultRecord>()) { result.payloadBytes += $0.sealedPayload.count }
            payloadByteCount = result.payloadBytes
        }
        var folderBytes = 0
        try batches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "folder" }, sortBy: [SortDescriptor(\VaultRecord.createdAt)])) { record in
            let value = try payload(record)
            let count = try context.fetchCount(request(scope: .folder(record.id)))
            let displayed = VaultLimits.displayPrefix(value.text, bytes: 256)
            folderBytes += displayed.utf8.count
            guard folderBytes <= VaultLimits.folderDisplayBytes else { throw VaultError.capacity }
            result.folders.append(FolderItem(id: record.id, name: displayed, count: count))
        }
        return result
    }

    func find(_ id: UUID) throws -> VaultRecord {
        let (context, _) = try access()
        var descriptor = FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { throw VaultError.missingRecord }
        return record
    }

    func text(_ id: UUID) throws -> String {
        let record = try find(id)
        guard record.kind == "clip" else { throw VaultError.missingRecord }
        return try payload(record).text
    }

    private func fingerprint(_ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: duplicateKey))
    }

    private func index(_ metadata: RecordMetadata, text: String) {
        let digest = fingerprint(text)
        if let previous = fingerprints[metadata.id], previous != digest, duplicates[previous]?.id == metadata.id { duplicates[previous] = nil }
        guard fingerprints[metadata.id] != nil || fingerprints.count < 5_000 else { indexComplete = false; return }
        fingerprints[metadata.id] = digest
        if duplicates[digest] == nil || duplicates[digest]!.date <= metadata.createdAt { duplicates[digest] = (metadata.id, metadata.createdAt) }
    }

    func duplicate(_ text: String) throws -> VaultRecord? {
        let digest = fingerprint(text)
        if let match = duplicates[digest] {
            let record = try find(match.id)
            // The digest only selects a candidate; authenticated text must still match exactly.
            if try payload(record).text == text { return record }
        }
        // A duplicate may remain after the indexed newest copy was deleted.
        for (id, stored) in fingerprints where stored == digest {
            let record = try find(id)
            if try payload(record).text == text { return record }
        }
        if !indexComplete {
            var match: VaultRecord?
            try batches(request()) { record in
                if match == nil, try payload(record).text == text { match = record }
            }
            return match
        }
        return nil
    }

    func remove(_ record: VaultRecord) throws {
        let (context, _) = try access()
        if let bytes = payloadByteCount { payloadByteCount = bytes - record.sealedPayload.count }
        if let digest = fingerprints.removeValue(forKey: record.id), duplicates[digest]?.id == record.id { duplicates[digest] = nil }
        if let removed = decoded.removeValue(forKey: record.id) { decodedBytes -= removed.bytes }
        context.delete(record)
    }

    private func cache(_ value: RecordPayload, metadata: RecordMetadata, sealed: Data) {
        if let old = decoded.removeValue(forKey: metadata.id) { decodedBytes -= old.bytes }
        let bytes = value.text.utf8.count + (value.source?.utf8.count ?? 0)
        guard bytes <= VaultLimits.decryptedCacheBytes else { return }
        if decodedBytes + bytes > VaultLimits.decryptedCacheBytes { decoded.removeAll(); decodedBytes = 0 }
        decoded[metadata.id] = CachedPayload(metadata: metadata, sealed: sealed, payload: value, bytes: bytes)
        decodedBytes += bytes
    }

    private func createHeader() throws {
        try write(RecordMetadata(id: Self.headerID, kind: .header, createdAt: Date(timeIntervalSince1970: 0), isPinned: false, folderID: nil),
                  payload: RecordPayload(text: "ZPaste encrypted history v1", source: nil))
        try save()
    }
}
