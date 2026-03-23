import Foundation
import Security

public enum DarkgramAIKeychainError: Error {
    case unknown(OSStatus)
}

public final class DarkgramAIKeychainStore {
    public static let shared = DarkgramAIKeychainStore()

    private let service: String

    private init() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.darkgram"
        self.service = "\(bundleIdentifier).darkgram.ai"
    }

    private func listAccount(for provider: DarkgramAIProviderKind) -> String {
        return "\(provider.rawValue).keys"
    }

    public func setAPIKey(_ apiKey: String, for provider: DarkgramAIProviderKind) throws {
        let normalizedValue = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedValue.isEmpty {
            try self.deleteAPIKey(for: provider)
            return
        }
        try self.setAPIKeys([normalizedValue], for: provider)
    }

    public func apiKey(for provider: DarkgramAIProviderKind) throws -> String? {
        return try self.apiKeys(for: provider).first
    }

    public func setAPIKeys(_ apiKeys: [String], for provider: DarkgramAIProviderKind) throws {
        var normalizedValues: [String] = []
        var seen = Set<String>()
        for key in apiKeys {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty && !seen.contains(normalized) {
                normalizedValues.append(normalized)
                seen.insert(normalized)
            }
        }
        if normalizedValues.isEmpty {
            try self.deleteAPIKey(for: provider)
            return
        }

        let encodedValue: Data
        do {
            encodedValue = try JSONEncoder().encode(normalizedValues)
        } catch {
            throw DarkgramAIKeychainError.unknown(errSecParam)
        }

        try self.upsertData(encodedValue, account: self.listAccount(for: provider))
    }

    public func apiKeys(for provider: DarkgramAIProviderKind) throws -> [String] {
        if let data = try self.copyData(account: self.listAccount(for: provider)) {
            if let decoded = try? JSONDecoder().decode([String].self, from: data) {
                let normalized = decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DarkgramAIKeychainError.unknown(status)
        }

        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedValue.isEmpty ? [] : [normalizedValue]
    }

    public func deleteAPIKey(for provider: DarkgramAIProviderKind) throws {
        try self.deleteAccount(self.listAccount(for: provider))
        try self.deleteAccount(provider.rawValue)
    }

    private func upsertData(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account
        ]

        let addQuery: [String: Any] = baseQuery.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, new in new }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw DarkgramAIKeychainError.unknown(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw DarkgramAIKeychainError.unknown(status)
        }
    }

    private func copyData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw DarkgramAIKeychainError.unknown(status)
        }
        return data
    }

    private func deleteAccount(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DarkgramAIKeychainError.unknown(status)
        }
    }
}
