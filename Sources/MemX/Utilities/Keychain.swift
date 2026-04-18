import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.memx.anthropic"
    private static let account = "api_key"
    private static let legacyDefaultsKey = "anthropic_api_key"

    static func anthropicAPIKey() -> String? {
        migrateFromUserDefaultsIfNeeded()
        return readFromKeychain()
    }

    static func setAnthropicAPIKey(_ value: String?) throws {
        if let value {
            try upsert(value)
        } else {
            delete()
        }
    }

    // MARK: - Private

    private static func migrateFromUserDefaultsIfNeeded() {
        guard readFromKeychain() == nil,
              let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey),
              !legacy.isEmpty else { return }
        try? upsert(legacy)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    private static func readFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func upsert(_ value: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        if readFromKeychain() != nil {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            let attributes: [CFString: Any] = [kSecValueData: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status != errSecSuccess {
                throw KeychainError.updateFailed(status)
            }
        } else {
            let item: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
            ]
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecSuccess {
                throw KeychainError.addFailed(status)
            }
        }
    }

    private static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case addFailed(OSStatus)
    case updateFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .addFailed(let s):    return "Keychain add failed: \(s)"
        case .updateFailed(let s): return "Keychain update failed: \(s)"
        }
    }
}
