import Foundation
import Security
import UseMacEngine

/// The seal key (SafetySeal.swift) in the login Keychain: a generic password that UseMac creates.
///
/// It goes in the login keychain, not the data protection keychain, which would need a keychain-access-groups
/// entitlement. The item's default access list trusts only the app that created it, so another process, the
/// `security` tool included, can't read the key unless the user allows it in a macOS prompt. It never syncs to
/// iCloud. Tests never use this: they use an in-memory store.
final class SafetySealKeychain: SafetySealSecretStore {
    static let service = "app.usemac.safety-seal"
    static let account = "seal-key"

    struct KeychainError: Error {
        let status: OSStatus
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    func readSecret() throws -> Data? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func writeSecret(_ data: Data) throws {
        let updated = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }

        var item = itemQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "UseMac safety seal"
        item[kSecAttrDescription as String] = "UseMac uses it to notice changes to its safety settings made outside UseMac."
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
}
