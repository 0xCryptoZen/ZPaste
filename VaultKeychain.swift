import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// Authentication is enforced by the Keychain ACL, including for fresh installations.
protocol VaultKeyProviding: Sendable {
    func load(createIfMissing: Bool, reason: String, lease: VaultLease) throws -> SymmetricKey
    func cancel()
}

final class VaultKeychain: VaultKeyProviding, @unchecked Sendable {
    private let mutex = NSLock()
    private var context: LAContext?
    private let service = (Bundle.main.bundleIdentifier ?? "com.example.zpaste") + ".vault.v1"

    func cancel() {
        mutex.lock(); context?.invalidate(); context = nil; mutex.unlock()
    }

    func load(createIfMissing: Bool, reason: String, lease: VaultLease) throws -> SymmetricKey {
        let authentication = LAContext()
        authentication.localizedReason = reason
        authentication.touchIDAuthenticationAllowableReuseDuration = 0
        // Register and check cancellation atomically with respect to cancel().
        mutex.lock()
        do { try lease.check(); context = authentication; mutex.unlock() }
        catch { mutex.unlock(); authentication.invalidate(); throw error }
        defer {
            authentication.invalidate()
            mutex.lock(); if context === authentication { context = nil }; mutex.unlock()
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "history-key",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authentication
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            try lease.check()
            guard createIfMissing else { throw VaultError.missingKey }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               .userPresence, &error) else {
                throw VaultError.keychain(errSecParam)
            }
            let key = SymmetricKey(size: .bits256)
            var item = identity
            item[kSecAttrAccessControl as String] = access
            item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess || added == errSecDuplicateItem else { throw VaultError.keychain(added) }
            // Do not return the generated key: retrieving it must satisfy userPresence.
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw VaultError.keychain(status)
        }
        return SymmetricKey(data: data)
    }
}
