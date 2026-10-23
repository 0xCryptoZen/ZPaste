import Foundation
import CryptoKit

enum VaultCipher {
    private static func authenticatedData(_ metadata: RecordMetadata) throws -> Data {
        guard metadata.version == 1 else { throw VaultError.corrupt }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }

    static func seal(_ payload: RecordPayload, metadata: RecordMetadata, key: SymmetricKey) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(data, using: key, authenticating: authenticatedData(metadata))
        guard let combined = box.combined else { throw VaultError.corrupt }
        return combined
    }

    static func open(_ data: Data, metadata: RecordMetadata, key: SymmetricKey) throws -> RecordPayload {
        do {
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                                            authenticating: authenticatedData(metadata))
            return try JSONDecoder().decode(RecordPayload.self, from: plaintext)
        } catch { throw VaultError.corrupt }
    }
}
