import Foundation
import SwiftData

/// 一条剪贴板历史记录。
/// 属性都带默认值（CloudKit 同步要求属性可选或有默认值）。
@Model
final class Clip {
    var text: String = ""
    var createdAt: Date = .now
    var isPinned: Bool = false
    var sourceAppBundleID: String?

    @Relationship(deleteRule: .nullify, inverse: \Folder.clips)
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

/// 分组/文件夹。
@Model
final class Folder {
    var name: String = ""
    var createdAt: Date = .now

    @Relationship(deleteRule: .nullify, inverse: \Clip.folder)
    var clips: [Clip]? = nil

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}
