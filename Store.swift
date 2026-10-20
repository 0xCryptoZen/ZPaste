import Foundation
import SwiftData

/// 全局唯一的模型容器。
/// 优先 CloudKit 自动同步；失败时回退到纯本地，保证无签名也能启动。
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
        fatalError("无法初始化模型容器")
    }()
}
