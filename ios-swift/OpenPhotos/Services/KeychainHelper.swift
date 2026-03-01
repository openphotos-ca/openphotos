import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    func set(_ value: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Delete existing item if any
        let delStatus = SecItemDelete(query as CFDictionary)
        if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
            print("[KEYCHAIN] Delete failed service=\(service) account=\(account) status=\(delStatus)")
        }

        var attributes = query
        attributes[kSecValueData as String] = value
        // Use device-only keychain class for stronger security (no migration/sync)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("[KEYCHAIN] Add failed service=\(service) account=\(account) status=\(addStatus)")
        } else {
            print("[KEYCHAIN] Set OK service=\(service) account=\(account) size=\(value.count)")
        }
    }

    func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            print("[KEYCHAIN] Get failed service=\(service) account=\(account) status=\(status)")
            return nil
        }
        return item as? Data
    }

    func remove(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[KEYCHAIN] Remove failed service=\(service) account=\(account) status=\(status)")
        } else {
            print("[KEYCHAIN] Remove OK service=\(service) account=\(account)")
        }
    }
}
