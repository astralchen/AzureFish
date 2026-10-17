import Foundation
import Security

/// 将会话、安装身份、撤销队列和缓存密钥存入彼此独立的 Keychain 项。
@MainActor
final class KeychainValueStore: SecureValueStoring {
    private let service = "com.azurefish.account.v1"
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountFailure.storage }
        return data
    }
    func write(_ data: Data, key: String) throws {
        let query = query(key)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query
            attributes.forEach { new[$0.key] = $0.value }
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw AccountFailure.storage }
        } else if status != errSecSuccess { throw AccountFailure.storage }
    }
    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountFailure.storage }
    }
}
