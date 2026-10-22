import Foundation
import CryptoKit

@main
struct CipherTests {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Tampering was accepted") } catch { }
    }

    static func main() throws {
        let key = SymmetricKey(size: .bits256)
        let metadata = RecordMetadata(id: UUID(), kind: .clip, createdAt: Date(timeIntervalSince1970: 1234), isPinned: false, folderID: nil)
        let payload = RecordPayload(text: "test-private-body-秘密", source: "test.private.source")
        let a = try VaultCipher.seal(payload, metadata: metadata, key: key)
        let b = try VaultCipher.seal(payload, metadata: metadata, key: key)
        precondition(a != b, "Repeated writes must use fresh nonces")
        let opened = try VaultCipher.open(a, metadata: metadata, key: key)
        precondition(opened == payload)
        precondition(a.range(of: Data(payload.text.utf8)) == nil)
        rejects { _ = try VaultCipher.open(a, metadata: metadata, key: SymmetricKey(size: .bits256)) }
        var damaged = a
        damaged[damaged.count - 1] ^= 1
        rejects { _ = try VaultCipher.open(damaged, metadata: metadata, key: key) }
        for changed in [
            RecordMetadata(id: UUID(), kind: .clip, createdAt: metadata.createdAt, isPinned: false, folderID: nil),
            RecordMetadata(id: metadata.id, kind: .folder, createdAt: metadata.createdAt, isPinned: false, folderID: nil),
            RecordMetadata(id: metadata.id, kind: .clip, createdAt: .distantPast, isPinned: false, folderID: nil),
            RecordMetadata(id: metadata.id, kind: .clip, createdAt: metadata.createdAt, isPinned: true, folderID: nil),
            RecordMetadata(id: metadata.id, kind: .clip, createdAt: metadata.createdAt, isPinned: false, folderID: UUID())
        ] {
            rejects { _ = try VaultCipher.open(a, metadata: changed, key: key) }
        }
        rejects { _ = try VaultCipher.open(Data(), metadata: metadata, key: key) }
        precondition(VaultLimits.acceptsNewText(String(repeating: "a", count: 256 * 1024)))
        precondition(!VaultLimits.acceptsNewText(String(repeating: "密", count: 100_000)))
        let combining = "a" + String(repeating: "\u{0301}", count: 5_000)
        precondition(VaultLimits.displayPrefix(combining, bytes: 256).utf8.count <= 256)
        precondition(VaultLimits.displayPrefix("秘密🙂", bytes: 7) == "秘密")
        print("Cipher tests passed: round trip, fresh nonces, wrong keys, all authenticated metadata, corruption, UTF-8 limits")
    }
}
