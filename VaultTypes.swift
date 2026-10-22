import Foundation

enum VaultLimits {
    static let textBytes = 256 * 1024
    static let payloadBytes = 20 * 1024 * 1024
    static let pinnedItems = 100
    static let pageSize = 100
    static func acceptsNewText(_ text: String) -> Bool { text.utf8.count <= textBytes }
}

enum RecordKind: String, Codable, Sendable { case clip, folder }

struct RecordMetadata: Codable, Equatable, Sendable {
    var id: UUID
    var kind: RecordKind
    var createdAt: Date
    var isPinned: Bool
    var folderID: UUID?
    var version: Int = 1
}

struct RecordPayload: Codable, Equatable, Sendable {
    var text: String
    var source: String?
}

struct ClipItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let isPinned: Bool
    let sourceAppBundleID: String?
    let folderID: UUID?
    var isPreviewOnly = false
}

struct FolderItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let count: Int
}

enum HistoryScope: Hashable, Sendable { case all, pinned, folder(UUID) }

struct VaultPage: Sendable {
    var clips: [ClipItem] = []
    var nextOffset: Int?
}

struct VaultSummary: Sendable {
    var folders: [FolderItem] = []
    var count = 0
    var pinned = 0
    var payloadBytes = 0
}

struct RetentionSettings: Sendable {
    let days: Int
    let limit: Int
    let enabled: Bool
    static let safe = RetentionSettings(days: 7, limit: 500, enabled: true)
}

enum VaultError: Error, LocalizedError {
    case locked, missingKey, keychain(Int32), corrupt, storage, migration, tooLarge, capacity, pinLimit, missingRecord
    var errorDescription: String? {
        switch self {
        case .locked: return "History is locked. Unlock to resume recording."
        case .missingKey: return "The key for this history is missing. The encrypted store was preserved. Restore the original key on this Mac; no replacement key was created."
        case .keychain: return "Keychain access failed or authentication was cancelled. History remains locked. Use a signed build with a stable app identity and try again."
        case .corrupt: return "History authentication failed. Recording stopped; the stored data was preserved."
        case .storage: return "History could not be saved. Recording stopped; check available storage before unlocking again."
        case .migration: return "The old history could not be safely migrated. Recording stopped and the original files were preserved."
        case .tooLarge: return "This copy exceeds the 256 KiB recording limit and was skipped."
        case .capacity: return "History exceeds its capacity. Recording is paused. Remove history or apply the recommended limits, then resume."
        case .pinLimit: return "The 100-pin limit has been reached. Existing pins were kept."
        case .missingRecord: return "This item is no longer available. Refresh history and try again."
        }
    }
}

/// Invalidated synchronously on the UI thread, before the repository can process its lock message.
final class VaultLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func check() throws {
        lock.lock(); let allowed = valid; lock.unlock()
        guard allowed, !Task.isCancelled else { throw VaultError.locked }
    }
}
