import Foundation
import Security

enum KeychainStore {
    // Check setup state without loading the secret into the UI.
    static func containsKey(for provider: AIProvider = .openRouter) throws -> Bool {
        var query = base(for: provider)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw failure(status) }
        return true
    }
    static func read(for provider: AIProvider = .openRouter) throws -> String? {
        var query = base(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, for provider: AIProvider = .openRouter) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("Enter a nonempty \(provider.name) API key.")
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(for: provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base(for: provider)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw failure(add) }
        } else if status != errSecSuccess { throw failure(status) }
        UserDefaults.standard.removeObject(forKey: provider.modelCatalogCacheKey)
    }
    static func delete(for provider: AIProvider = .openRouter) throws {
        let status = SecItemDelete(base(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        UserDefaults.standard.removeObject(forKey: provider.modelCatalogCacheKey)
    }
    private static func base(for provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: provider.keychainService, kSecAttrAccount as String: "api-key"]
    }
    private static func failure(_ status: OSStatus) -> AppError {
        .message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}
