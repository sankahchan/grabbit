import Foundation
import Security

/// Minimal Keychain wrapper for Grabbit secrets (currently: the global
/// proxy password). Uses the login keychain; Grabbit is not sandboxed.
///
/// `load` distinguishes "no such item" from a real Keychain failure so
/// callers never wipe a credential merely because the Keychain hiccuped.
enum KeychainStore {
    static let service = "com.sankahchan.grabbit"

    enum LoadError: Error, Equatable {
        case notFound
        case failed(OSStatus)
    }

    /// Creates or updates the generic-password item. True on success.
    @discardableResult
    static func save(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Reads the secret. `.failure(.notFound)` means no item exists;
    /// `.failure(.failed)` means the Keychain errored — the caller must
    /// NOT treat that as "no password" and wipe anything.
    static func load(account: String) -> Result<String, LoadError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return .failure(status == errSecItemNotFound ? .notFound : .failed(status))
        }
        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8)
        else { return .failure(.failed(errSecDecode)) }
        return .success(secret)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
