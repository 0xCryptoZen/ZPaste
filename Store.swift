import Foundation
import SwiftData

/// The app-wide model container.
/// Prefers CloudKit automatic sync; falls back to local-only storage so the
/// app still launches without signing.
enum Store {
    static let container: ModelContainer = {
        let schema = Schema([Clip.self, Folder.self])
        let cloudConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        let localConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        if let c = try? ModelContainer(for: schema, configurations: [cloudConfig]) {
            return c
        }
        if let c = try? ModelContainer(for: schema, configurations: [localConfig]) {
            return c
        }
        fatalError("Failed to initialize the model container")
    }()
}