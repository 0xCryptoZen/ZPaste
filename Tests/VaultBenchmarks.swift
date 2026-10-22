import Foundation
import SwiftData
import CryptoKit
import Darwin

@main
struct VaultBenchmarks {
    static func milliseconds(_ action: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await action()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)]
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let policy = RetentionSettings(days: 0, limit: 0, enabled: false)
        print("BENCHMARK environment=\(ProcessInfo.processInfo.operatingSystemVersionString) processors=\(ProcessInfo.processInfo.processorCount) configuration=optimized syntheticTextBytes~=256")
        for count in [500, 1_000, 5_000] {
            let repository = VaultRepository(paths: StorePaths(directory: root, legacy: root.appendingPathComponent("none")), memoryOnly: true)
            let lease = VaultLease()
            _ = try await repository.unlock(key: key, lease: lease)
            let schema = Schema([Clip.self, Folder.self])
            let legacy = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let context = ModelContext(legacy)
            context.autosaveEnabled = false
            for index in 0..<count {
                let text = "Synthetic clipboard note \(index): " + String(repeating: "example text ", count: 18)
                let date = Date(timeIntervalSince1970: Double(index))
                try await repository.record(text: text, source: "synthetic.app", merge: false, retention: policy, now: date)
                context.insert(Clip(text: text, createdAt: date, sourceAppBundleID: "synthetic.app"))
            }
            try context.save()
            // Baseline: the old view held every plaintext model and filtered/sorted that array.
            let all = try context.fetch(FetchDescriptor<Clip>(sortBy: [SortDescriptor(\Clip.createdAt, order: .reverse)]))
            var recentTimes: [Double] = [], searchTimes: [Double] = [], baselineTimes: [Double] = []
            for _ in 0..<20 {
                recentTimes.append(try await milliseconds {
                    let page = try await repository.page(scope: .all, search: "", limit: 8, recent: true)
                    precondition(page.clips.count == 8)
                })
                searchTimes.append(try await milliseconds {
                    let page = try await repository.page(scope: .all, search: "not-in-this-fixture")
                    precondition(page.clips.isEmpty)
                })
                baselineTimes.append(await milliseconds {
                    let matches = all.filter { $0.text.localizedCaseInsensitiveContains("not-in-this-fixture") }
                        .sorted { $0.createdAt > $1.createdAt }
                    precondition(matches.isEmpty)
                })
            }
            let p95 = percentile(searchTimes, 0.95)
            print(String(format: "BENCHMARK items=%d recent8_p50_ms=%.2f recent8_p95_ms=%.2f encrypted_search_p50_ms=%.2f encrypted_search_p95_ms=%.2f baseline_plaintext_array_search_p95_ms=%.2f",
                         count, percentile(recentTimes, 0.5), percentile(recentTimes, 0.95), percentile(searchTimes, 0.5), p95, percentile(baselineTimes, 0.95)))
            if count == 1_000 { precondition(p95 <= 200 && percentile(recentTimes, 0.95) <= 200, "Repository latency exceeds the initial 200 ms budget") }
            lease.invalidate(); await repository.lock()
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { print("BENCHMARK combined_fixture_process_peak_rss_bytes=\(usage.ru_maxrss) (not app idle RSS)") }
    }
}
