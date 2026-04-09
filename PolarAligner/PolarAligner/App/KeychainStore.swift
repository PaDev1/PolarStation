import Foundation
import Security

/// Simple Keychain wrapper for storing sensitive string values (API keys).
/// Uses kSecClassGenericPassword with a per-app service identifier.
enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.polarstation.app"

    static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func set(_ key: String, value: String) {
        let data = Data(value.utf8)
        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: key,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Migrate a plaintext UserDefaults value to Keychain and remove it from UserDefaults.
    /// No-op if the key is already in Keychain or not present in UserDefaults.
    static func migrateFromUserDefaults(_ key: String) {
        guard get(key) == nil,
              let old = UserDefaults.standard.string(forKey: key),
              !old.isEmpty else { return }
        set(key, value: old)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
