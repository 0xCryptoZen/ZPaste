import Foundation
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var page = VaultPage()
    @Published private(set) var loading = false
    private var queryID = UUID()

    func clear() { queryID = UUID(); page = VaultPage(); loading = false }

    func load(scope: HistoryScope, search: String, offset: Int = 0, limit: Int = 100, byteLimit: Int = VaultLimits.payloadBytes / 2) async {
        let vault = VaultSession.shared
        guard vault.isUnlocked, let repository = vault.repository else { clear(); return }
        let query = UUID()
        queryID = query
        let revision = vault.revision
        loading = true
        defer { if queryID == query { loading = false } }
        do {
            if !search.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
            let page = try await repository.page(scope: scope, search: search, offset: offset, limit: limit, byteLimit: byteLimit)
            try Task.checkCancellation()
            guard queryID == query, vault.isUnlocked, revision == vault.revision else { return }
            self.page = page
        } catch is CancellationError { }
        catch VaultError.locked { }
        catch { if queryID == query, vault.isUnlocked, revision == vault.revision { vault.fail(error) } }
    }
}

struct HistoryQuery: Equatable {
    let revision: UUID
    let scope: HistoryScope
    let search: String
    let offset: Int
}
