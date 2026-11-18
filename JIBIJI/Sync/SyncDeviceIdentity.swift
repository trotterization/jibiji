import Foundation
import Security

/// A backup restored onto another device must not reuse the original sync writer ID.
enum SyncDeviceIdentity {
    static func load() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "JibijiFolderSync",
                                   kSecAttrAccount as String: "device",
                                   kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data,
           let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil { return id }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let id = UUID().uuidString
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "JibijiFolderSync", kSecAttrAccount as String: "device",
                                  kSecValueData as String: Data(id.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return id
    }
}
