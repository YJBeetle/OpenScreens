import Foundation
import Security

/// Keychain-backed storage for per-connection passwords. Passwords never enter
/// the JSON connection library.
public enum OpenScreensCredentials {
    private static let service = "app.openscreens.credentials"

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
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, for id: UUID) {
        setSecret(password, kind: "vnc", for: id)
    }

    public static func deletePassword(for id: UUID) {
        deleteSecret(kind: "vnc", for: id)
    }

    public static func setSecret(_ value: String, kind: String, for id: UUID) {
        deleteSecret(kind: kind, for: id)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func deleteSecret(kind: String, for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func account(_ id: UUID, _ kind: String) -> String {
        kind == "vnc" ? id.uuidString : "\(id.uuidString).\(kind)"
    }
}
