import Foundation
import SwiftData

extension VaultRepository {
    func record(text: String, source: String, merge: Bool, retention: RetentionSettings, now: Date = .now) throws {
        guard VaultLimits.acceptsNewText(text) else { throw VaultError.tooLarge }
        let (context, _) = try access()
        do {
            if try summary().payloadBytes > VaultLimits.payloadBytes { throw VaultError.capacity }
            try clean(retention: retention, now: now)
            var duplicate: VaultRecord?
            if merge {
                try batches(request()) { record in
                    if duplicate == nil, try payload(record).text == text { duplicate = record }
                }
            }
            var metadata = try duplicate?.metadata() ?? RecordMetadata(id: UUID(), kind: .clip, createdAt: now, isPinned: false, folderID: nil)
            metadata.createdAt = now
            let value = RecordPayload(text: text, source: source)
            let (_, key) = try access()
            let size = try VaultCipher.seal(value, metadata: metadata, key: key).count
            guard try summary().payloadBytes - (duplicate?.sealedPayload.count ?? 0) + size <= VaultLimits.payloadBytes else { throw VaultError.capacity }
            try write(metadata, payload: value, existing: duplicate)
            try save()
            try clean(retention: retention, now: now)
        } catch { context.rollback(); throw error }
    }

    func clean(retention: RetentionSettings, now: Date = .now) throws {
        guard retention.enabled, retention.days > 0 || retention.limit > 0 else { return }
        let (context, _) = try access()
        if retention.days > 0 {
            let boundary = now.addingTimeInterval(-Double(retention.days) * 86_400)
            try deleteBatches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "clip" && !$0.isPinned && $0.createdAt < boundary }))
        }
        if retention.limit > 0 {
            let descriptor = FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "clip" && !$0.isPinned }, sortBy: [SortDescriptor(\VaultRecord.createdAt, order: .reverse), SortDescriptor(\VaultRecord.orderID)])
            try deleteBatches(descriptor, keeping: retention.limit)
        }
        if context.hasChanges { try save() }
    }

    private func deleteBatches(_ descriptor: FetchDescriptor<VaultRecord>, keeping: Int = 0) throws {
        let (context, _) = try access()
        var descriptor = descriptor
        descriptor.fetchLimit = VaultLimits.pageSize
        descriptor.fetchOffset = keeping
        while true {
            try checkLease()
            let records = try context.fetch(descriptor)
            if records.isEmpty { break }
            for record in records { _ = try payload(record); context.delete(record) }
            try save()
        }
    }

    func changeClip(_ id: UUID, pinned: Bool? = nil, folderID: UUID?? = nil) throws {
        let (context, _) = try access()
        do {
            let record = try find(id)
            let value = try payload(record)
            var metadata = try record.metadata()
            guard metadata.kind == .clip else { throw VaultError.corrupt }
            if let pinned {
                let count = try summary().pinned
                if pinned && !record.isPinned && count >= VaultLimits.pinnedItems { throw VaultError.pinLimit }
                metadata.isPinned = pinned
            }
            if let folderID {
                if let id = folderID { guard try find(id).metadata().kind == .folder else { throw VaultError.missingRecord } }
                metadata.folderID = folderID
            }
            try write(metadata, payload: value, existing: record)
            try save()
        } catch { context.rollback(); throw error }
    }

    func saveFolder(id: UUID?, name: String) throws {
        let (context, _) = try access()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256 else { throw VaultError.tooLarge }
        do {
            let record = try id.map { try find($0) }
            if let record { _ = try payload(record); guard record.kind == "folder" else { throw VaultError.corrupt } }
            let metadata = try record?.metadata() ?? RecordMetadata(id: UUID(), kind: .folder, createdAt: .now, isPinned: false, folderID: nil)
            let value = RecordPayload(text: name, source: nil)
            let (_, key) = try access()
            let bytes = try VaultCipher.seal(value, metadata: metadata, key: key).count
            guard try summary().payloadBytes - (record?.sealedPayload.count ?? 0) + bytes <= VaultLimits.payloadBytes else { throw VaultError.capacity }
            try write(metadata, payload: value, existing: record)
            try save()
        } catch { context.rollback(); throw error }
    }

    func delete(_ id: UUID) throws {
        let (context, _) = try access()
        do {
            let record = try find(id)
            let metadata = try record.metadata()
            _ = try payload(record)
            if metadata.kind == .folder {
                try batches(request(scope: .folder(id))) { clip in
                    let value = try payload(clip)
                    var metadata = try clip.metadata(); metadata.folderID = nil
                    try write(metadata, payload: value, existing: clip)
                }
            }
            context.delete(record)
            try save()
        } catch { context.rollback(); throw error }
    }

    func clear(includePinned: Bool) throws {
        if includePinned { try deleteBatches(FetchDescriptor<VaultRecord>()) }
        else { try deleteBatches(FetchDescriptor<VaultRecord>(predicate: #Predicate { $0.kind == "clip" && !$0.isPinned })) }
    }
}
