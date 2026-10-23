import Foundation
import SwiftData

struct StorePaths: Sendable {
    let directory: URL
    let legacy: URL
    var database: URL { directory.appendingPathComponent("history.store") }
    var committed: URL { directory.appendingPathComponent("committed-v1") }
    var pending: URL { directory.appendingPathComponent("migration-pending-v1") }

    static func standard() throws -> StorePaths {
        let schema = Schema([Clip.self, Folder.self])
        let old = ModelConfiguration(schema: schema, allowsSave: false, cloudKitDatabase: .none).url
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        return StorePaths(directory: support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.example.zpaste")
            .appendingPathComponent("EncryptedHistory-v1"), legacy: old)
    }

    var requiresExistingKey: Bool {
        FileManager.default.fileExists(atPath: committed.path) || FileManager.default.fileExists(atPath: database.path)
    }

    func prepare() throws {
        let fm = FileManager.default
        for url in [directory.deletingLastPathComponent(), directory] where fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw VaultError.storage }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for file in [database, committed, pending] + sidecars(database) where fm.fileExists(atPath: file.path) {
            try requireRegularFile(file)
        }
    }

    func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw VaultError.storage }
    }

    func sidecars(_ url: URL) -> [URL] { [URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] }

    func mark(_ url: URL) throws {
        try Data("1".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func protectFiles() throws {
        for url in [database] + sidecars(database) where FileManager.default.fileExists(atPath: url.path) {
            try requireRegularFile(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func removeDatabase(_ url: URL) throws {
        for file in [url] + sidecars(url) where FileManager.default.fileExists(atPath: file.path) {
            try requireRegularFile(file)
            try FileManager.default.removeItem(at: file)
        }
    }
}
