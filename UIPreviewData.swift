import Foundation
import SwiftData

/// A disposable, in-memory fixture for visual checks. It never starts clipboard recording.
enum UIPreviewData {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-preview") || Bundle.main.object(forInfoDictionaryKey: "ZPasteUIPreview") as? Bool == true }

    @MainActor
    static func populate(_ context: ModelContext) throws {
        let work = Folder(name: "Work")
        let personal = Folder(name: "Personal")
        context.insert(work)
        context.insert(personal)
        let samples: [(String, TimeInterval, Bool, String, Folder?)] = [
            ("https://developer.apple.com/design/human-interface-guidelines", -7200, true, "com.apple.Safari", work),
            ("Good design is as little design as possible.", -180, true, "com.apple.Notes", personal),
            ("Design review\nRefine the sidebar, simplify the toolbar, and make every interaction feel at home on the Mac.", -300, false, "com.apple.Notes", work),
            ("https://www.apple.com/mac/", -960, false, "com.apple.Safari", nil),
            ("Thanks for the update. The new build looks good, and I'll share my notes after the review.", -3600, false, "com.apple.mail", work),
            ("Meeting notes\n• Keep the default actions simple\n• Make keyboard navigation predictable\n• Respect light and dark appearance", -86400, false, "com.apple.TextEdit", nil),
            ("A place for the things you copy, ready when you need them.", -3 * 86400, false, "com.apple.Notes", personal)
        ]
        for (text, age, pinned, source, folder) in samples {
            context.insert(Clip(text: text, createdAt: Date.now.addingTimeInterval(age), isPinned: pinned, sourceAppBundleID: source, folder: folder))
        }
        try context.save()
    }
}
