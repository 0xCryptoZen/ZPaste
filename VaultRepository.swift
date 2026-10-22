import Foundation
import SwiftData
import CryptoKit

/// Contexts, keys and persistent models stay on this serial executor.
actor VaultRepository {
    private var container: ModelContainer?
    private var context: ModelContext?
    private var key: SymmetricKey?
    private var lease: VaultLease?
    let paths: StorePaths
    private let memoryOnly: Bool

    init(paths: StorePaths, memoryOnly: Bool = false) { self.paths = paths; self.memoryOnly = memoryOnly }
    func requiresExistingKey() -> Bool { !memoryOnly && paths.requiresExistingKey }

    func unlock(key: SymmetricKey, lease: VaultLease) throws -> Bool {
        try lease.check()
        self.key = key; self.lease = lease
        do {
            if memoryOnly {
                let schema = Schema([VaultRecord.self])
                container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                context = ModelContext(container!)
                context?.autosaveEnabled = false
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
                if fm.fileExists(atPath: paths.legacy.path) { try paths.removeDatabase(paths.legacy) }
                try fm.removeItem(at: paths.pending)
            }
            return hadLegacy
        } catch {
            context?.rollback(); lock()
            throw error
        }
    }

    func lock() { key = nil; lease = nil; context = nil; container = nil }

    private func openStore() throws {
        let schema = Schema([VaultRecord.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: paths.database, cloudKitDatabase: .none)])
        context = ModelContext(container!)
        context?.autosaveEnabled = false
        try paths.protectFiles()
    }

    func access() throws -> (ModelContext, SymmetricKey) {
        try lease?.check()
        guard let context, let key, lease != nil else { throw VaultError.locked }
        return (context, key)
    }

    func checkLease() throws { _ = try access() }

    func payload(_ record: VaultRecord) throws -> RecordPayload {
        let (_, key) = try access()
        return try VaultCipher.open(record.sealedPayload, metadata: record.metadata(), key: key)
    }

    func write(_ metadata: RecordMetadata, payload: RecordPayload, existing: VaultRecord? = nil) throws {
        let (context, key) = try access()
        let sealed = try VaultCipher.seal(payload, metadata: metadata, key: key)
        if let existing {
            existing.createdAt = metadata.createdAt; existing.isPinned = metadata.isPinned
            existing.pinRank = metadata.isPinned ? 1 : 0
            existing.folderID = metadata.folderID; existing.sealedPayload = sealed
        } else { context.insert(VaultRecord(metadata: metadata, sealedPayload: sealed)) }
    }

    func save() throws {
        let (context, _) = try access()
        do {
            try context.save()
            if !memoryOnly { try paths.protectFiles() }
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
        var folders = Set<UUID>()
        try batches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "folder" })) { record in
            _ = try payload(record)
            guard record.folderID == nil, !record.isPinned else { throw VaultError.corrupt }
            folders.insert(record.id)
        }
        try batches(request()) { record in
            _ = try payload(record)
            if let folder = record.folderID, !folders.contains(folder) { throw VaultError.corrupt }
        }
        let known = try context.fetchCount(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "clip" || $0.kind == "folder" }))
        guard known == (try context.fetchCount(FetchDescriptor<VaultRecord>())) else { throw VaultError.corrupt }
    }

    func page(scope: HistoryScope, search: String, offset: Int = 0, limit: Int = VaultLimits.pageSize,
              byteLimit: Int = VaultLimits.payloadBytes / 2, recent: Bool = false) throws -> VaultPage {
        let (context, _) = try access()
        var descriptor = request(scope: scope)
        if recent { descriptor.sortBy = [SortDescriptor(\VaultRecord.createdAt, order: .reverse), SortDescriptor(\VaultRecord.orderID)] }
        descriptor.fetchLimit = VaultLimits.pageSize
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
                let oversized = value.text.utf8.count > byteLimit
                let displayed = oversized ? String(value.text.prefix(2_048)) : value.text
                guard bytes + displayed.utf8.count <= byteLimit else {
                    page.nextOffset = (descriptor.fetchOffset ?? 0) + index
                    return page
                }
                bytes += displayed.utf8.count
                page.clips.append(ClipItem(id: record.id, text: displayed, createdAt: record.createdAt,
                                          isPinned: record.isPinned, sourceAppBundleID: value.source, folderID: record.folderID,
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
        try batches(FetchDescriptor<VaultRecord>()) { result.payloadBytes += $0.sealedPayload.count }
        try batches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "folder" }, sortBy: [SortDescriptor(\VaultRecord.createdAt)])) { record in
            let value = try payload(record)
            let count = try context.fetchCount(request(scope: .folder(record.id)))
            result.folders.append(FolderItem(id: record.id, name: value.text, count: count))
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
}
