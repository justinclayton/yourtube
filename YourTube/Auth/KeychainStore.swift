import Foundation
import Security

/// Minimal Keychain wrapper for the OAuth refresh token.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlock` so background refresh can still
/// read the token while the phone is locked.
struct KeychainStore {
    let service: String

    init(service: String = "net.claytons.yourtube.oauth") {
        self.service = service
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(message ?? "unknown")"
            }
        }
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func set(_ value: String?, for key: String) throws {
        guard let value, let data = value.data(using: .utf8) else {
            try remove(key)
            return
        }

        let status = SecItemCopyMatching(query(for: key) as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let update = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(query(for: key) as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var attributes = query(for: key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func get(_ key: String) -> String? {
        var attributes = query(for: key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
