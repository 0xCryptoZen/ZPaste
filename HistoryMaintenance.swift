import Foundation
import SwiftData

@MainActor
enum HistoryMaintenance {
    static func record(
        text: String, source: String?, mergeDuplicates: Bool, in context: ModelContext,
        now: Date = .now
    ) throws {
        var existing: Clip?
        if mergeDuplicates {
            var request = FetchDescriptor<Clip>(
                predicate: #Predicate { $0.text == text },
                sortBy: [SortDescriptor(\Clip.createdAt, order: .reverse)]
            )
            request.fetchLimit = 1
            existing = try context.fetch(request).first
        }
        if let existing {
            existing.createdAt = now
            existing.sourceAppBundleID = source
        } else {
            context.insert(Clip(text: text, createdAt: now, sourceAppBundleID: source))
        }
        try context.save()
    }

    static func clean(
        in context: ModelContext, days: Int, limit: Int, now: Date = .now
    ) throws {
        guard days > 0 || limit > 0 else { return }
        let clips = try context.fetch(FetchDescriptor<Clip>(
            sortBy: [SortDescriptor(\Clip.createdAt, order: .reverse)]
        ))
        var keptUnpinned = 0
        for clip in clips where !clip.isPinned {
            if HistoryPolicy.shouldExpire(createdAt: clip.createdAt, isPinned: false, days: days, now: now) {
                context.delete(clip)
            } else {
                keptUnpinned += 1
                if limit > 0 && keptUnpinned > limit { context.delete(clip) }
            }
        }
        if context.hasChanges { try context.save() }
    }

    static func clearUnpinned(in context: ModelContext) throws {
        for clip in try context.fetch(FetchDescriptor<Clip>()) where !clip.isPinned {
            context.delete(clip)
        }
        try context.save()
    }
}
