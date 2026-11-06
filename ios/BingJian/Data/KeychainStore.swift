import Foundation
import Security

enum KeychainStore {
    static let service = "com.bingjian.health.credentials"

    static func save(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key]
        // 原地更新已有凭据，写入失败时保留原值。
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw saveError(updateStatus) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // 其他任务可能在查询与新增之间写入了同一条凭据。
            let retryStatus = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            guard retryStatus == errSecSuccess else { throw saveError(retryStatus) }
        } else if addStatus != errSecSuccess {
            throw saveError(addStatus)
        }
    }

    private static func saveError(_ status: OSStatus) -> APIError {
        if status == errSecMissingEntitlement {
            return APIError(code: "KEYCHAIN_ENTITLEMENT", message: "当前安装包缺少安全存储授权，请安装修复后的测试包（\(status)）")
        }
        if status == errSecInteractionNotAllowed {
            return APIError(code: "KEYCHAIN_LOCKED", message: "安全存储暂不可用，请解锁设备后重试（\(status)）")
        }
        return APIError(code: "KEYCHAIN", message: "安全凭据保存失败（\(status)），请保留错误编号以便排查")
    }

    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
    }
}
