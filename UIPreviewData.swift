import Foundation

enum UIPreviewData {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-preview") || Bundle.main.object(forInfoDictionaryKey: "ZPasteUIPreview") as? Bool == true
    }

    static func populate(_ repository: VaultRepository) async throws {
        try await repository.saveFolder(id: nil, name: "Work")
        let summary = try await repository.summary()
        let folderID = summary.folders.first?.id
        let samples = [
            "https://developer.apple.com/design/human-interface-guidelines",
            "Your clipboard, encrypted on this Mac.",
            "Design review\nKeep the default actions simple and keyboard navigation predictable.",
            "Sample data only. Clipboard recording and pasting are disabled in this preview."
        ]
        for (index, text) in samples.enumerated() {
            try await repository.record(text: text, source: "com.apple.Notes", merge: false,
                retention: RetentionSettings(days: 0, limit: 0, enabled: false), now: Date.now.addingTimeInterval(-Double(index) * 600))
        }
        let page = try await repository.page(scope: .all, search: "")
        if let first = page.clips.first {
            try await repository.changeClip(first.id, pinned: true, folderID: .some(folderID))
        }
    }
}
