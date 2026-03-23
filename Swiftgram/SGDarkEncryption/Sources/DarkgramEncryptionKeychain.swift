import Foundation
import Security

public enum DarkgramEncryptionKeychainError: Error {
    case unknown(OSStatus)
}

public final class DarkgramEncryptionKeychainStore {
    public static let shared = DarkgramEncryptionKeychainStore()

    private let service: String
    private let account = "password"

    private init() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.darkgram"
        self.service = "\(bundleIdentifier).darkgram.encryption"
    }

    public func password() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DarkgramEncryptionKeychainError.unknown(status)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public func setPassword(_ password: String?) throws {
        let normalized = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty {
            try self.clearPassword()
            return
        }

        guard let data = normalized.data(using: .utf8) else {
            throw DarkgramEncryptionKeychainError.unknown(errSecParam)
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account
        ]
        let addQuery: [String: Any] = baseQuery.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, new in new }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw DarkgramEncryptionKeychainError.unknown(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw DarkgramEncryptionKeychainError.unknown(status)
        }
    }

    public func clearPassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DarkgramEncryptionKeychainError.unknown(status)
        }
    }
}
