import Foundation
import SwiftData

/// Live schema: authenticated operational metadata and ciphertext only.
@Model
final class VaultRecord {
    @Attribute(.unique) var id: UUID
    var kind: String
    var createdAt: Date
    var isPinned: Bool
    var folderID: UUID?
    var version: Int
    var sealedPayload: Data
    var pinRank: Int
    var orderID: String

    init(metadata: RecordMetadata, sealedPayload: Data) {
        id = metadata.id; kind = metadata.kind.rawValue; createdAt = metadata.createdAt
        isPinned = metadata.isPinned; folderID = metadata.folderID; version = metadata.version
        self.sealedPayload = sealedPayload
        pinRank = metadata.isPinned ? 1 : 0
        orderID = metadata.id.uuidString
    }

    func metadata() throws -> RecordMetadata {
        let identifier = id, pinned = isPinned
        guard let kind = RecordKind(rawValue: kind), pinRank == (pinned ? 1 : 0), orderID == identifier.uuidString else { throw VaultError.corrupt }
        return RecordMetadata(id: identifier, kind: kind, createdAt: createdAt, isPinned: pinned, folderID: folderID, version: version)
    }
}
