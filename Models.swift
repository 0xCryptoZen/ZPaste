import Foundation
import SwiftData

/// Historical plaintext schema, opened read-only during migration.
/// Keep its defaults and relationships stable so old stores remain readable.
@Model
final class Clip {
    var text: String = ""
    var createdAt: Date = Date.now
    var isPinned: Bool = false
    var sourceAppBundleID: String?

    @Relationship(deleteRule: .nullify)
    var folder: Folder?

    init(
        text: String,
        createdAt: Date = .now,
        isPinned: Bool = false,
        sourceAppBundleID: String? = nil,
        folder: Folder? = nil
    ) {
        self.text = text
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.sourceAppBundleID = sourceAppBundleID
        self.folder = folder
    }
}

/// A group/folder.
@Model
final class Folder {
    var name: String = ""
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Clip.folder)
    var clips: [Clip]? = nil

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}
