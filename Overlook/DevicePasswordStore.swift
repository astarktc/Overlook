import Foundation
import Security

/// Keychain-backed storage for saved device passwords, keyed by "host:port".
///
/// Saved passwords are only used to answer a genuine auth rejection from the
/// device (expired/invalid token). A saved password that the device rejects is
/// deleted so the operator gets re-prompted instead of looping on a stale value.
enum DevicePasswordStore {
    private static let service = "com.overlook.device-password"

    private static func account(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    private static func baseQuery(host: String, port: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port)
        ]
    }

    static func save(_ password: String, host: String, port: Int) {
        guard let data = password.data(using: .utf8) else { return }

        var query = baseQuery(host: host, port: port)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func load(host: String, port: Int) -> String? {
        var query = baseQuery(host: host, port: port)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(host: String, port: Int) {
        SecItemDelete(baseQuery(host: host, port: port) as CFDictionary)
    }
}
