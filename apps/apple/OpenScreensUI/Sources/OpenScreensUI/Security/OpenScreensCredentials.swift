import Foundation
import Security
import os

/// Keychain-backed storage for per-connection passwords. Passwords never enter
/// the JSON connection library.
public enum OpenScreensCredentials {
    private static let service = "app.openscreens.credentials"
    private static let logger = Logger(subsystem: "app.openscreens", category: "Credentials")

    public static func password(for id: UUID) -> String? {
        secret(kind: "vnc", for: id)
    }

    public static func secret(kind: String, for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain read failed for \(kind, privacy: .public): \(status)")
        }
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setPassword(_ password: String, for id: UUID) -> Bool {
        setSecret(password, kind: "vnc", for: id)
    }

    public static func deletePassword(for id: UUID) {
        deleteSecret(kind: "vnc", for: id)
    }

    /// Stores `value` under the connection's Keychain account. Returns false
    /// when the system rejects the write, so callers can tell the user instead
    /// of silently connecting without a password. An existing item is updated
    /// in place so a failed write does not erase the previous password.
    @discardableResult
    public static func setSecret(_ value: String, kind: String, for id: UUID) -> Bool {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes.merge(updates) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            logger.error("Keychain write failed for \(kind, privacy: .public): \(status)")
        }
        return status == errSecSuccess
    }

    public static func deleteSecret(kind: String, for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(kind, privacy: .public): \(status)")
        }
    }

    private static func account(_ id: UUID, _ kind: String) -> String {
        kind == "vnc" ? id.uuidString : "\(id.uuidString).\(kind)"
    }
}
