import Foundation
import SwiftData

@main
struct StorageTests {
    @MainActor
    static func main() throws {
        let schema = Schema([Clip.self, Folder.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let folder = Folder(name: "Keep")
        context.insert(folder)
        let pin = Clip(text: "pinned", createdAt: now.addingTimeInterval(-40 * 86_400), isPinned: true, folder: folder)
        context.insert(pin)
        context.insert(Clip(text: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        context.insert(Clip(text: "recent", createdAt: now.addingTimeInterval(-60)))
        context.insert(Clip(text: "newest", createdAt: now))
        try context.save()
        precondition(folder.clips?.contains(where: { $0 === pin }) == true, "Inverse relationship must be maintained")

        try HistoryMaintenance.clean(in: context, days: 7, limit: 1, now: now)
        var clips = try context.fetch(FetchDescriptor<Clip>())
        precondition(Set(clips.map(\.text)) == ["pinned", "newest"], "Keep pins, remove expired and oldest excess items")
        try HistoryMaintenance.record(text: "pinned", source: "test.app", mergeDuplicates: true, in: context, now: now)
        precondition(pin.isPinned && pin.folder === folder && pin.createdAt == now, "Recopy must preserve pins and folders")
        let afterMerge = try context.fetchCount(FetchDescriptor<Clip>())
        precondition(afterMerge == 2, "Recopy must not insert a duplicate")
        try HistoryMaintenance.record(text: "newest", source: nil, mergeDuplicates: false, in: context, now: now)
        let afterInsert = try context.fetchCount(FetchDescriptor<Clip>())
        precondition(afterInsert == 3, "Duplicate merging can be disabled")
        try HistoryMaintenance.clearUnpinned(in: context)
        clips = try context.fetch(FetchDescriptor<Clip>())
        precondition(clips.count == 1 && clips[0].isPinned, "Bulk clear must keep pins")
        context.delete(folder)
        try context.save()
        precondition(pin.folder == nil, "Deleting a folder must keep its clips and clear the relationship")
        let afterFolderDelete = try context.fetchCount(FetchDescriptor<Clip>())
        precondition(afterFolderDelete == 1)
        print("Storage tests passed: inverse relationship, retention, limit, deduplication, pins, and folder deletion")
    }
}
