import Foundation
import Security
import TelegramCore
import MtProtoKit
import CryptoUtils

public enum DarkgramEncryptionLockState: Equatable {
    case none
    case success
    case failure
}

public struct DarkgramEncryptionResolvedText: Equatable {
    public let originalText: String
    public let displayText: String
    public let entities: [MessageTextEntity]?
    public let isEncryptedPayload: Bool
    public let lockState: DarkgramEncryptionLockState

    public init(
        originalText: String,
        displayText: String,
        entities: [MessageTextEntity]?,
        isEncryptedPayload: Bool,
        lockState: DarkgramEncryptionLockState
    ) {
        self.originalText = originalText
        self.displayText = displayText
        self.entities = entities
        self.isEncryptedPayload = isEncryptedPayload
        self.lockState = lockState
    }
}

public enum DarkgramEncryptionError: Error {
    case emptyInput
    case keyDerivationFailed
    case encryptionFailed
    case invalidCiphertext
    case invalidPayload
    case randomGenerationFailed(OSStatus)
}

private struct DarkgramEncryptedContent: Codable {
    let text: String
    let entities: [MessageTextEntity]?
}

public enum DarkgramEncryption {
    public static let defaultPassword = "0000"

    private static let version: UInt8 = 1
    private static let outerMagic = Data([0x44, 0x47, 0x45, 0x31]) // DGE1
    private static let innerMagic = Data([0x44, 0x47, 0x50, 0x31]) // DGP1
    private static let saltLength = 16
    private static let ivLength = 16
    private static let rounds = 100_000

    public static func resolvedPassword(_ password: String? = nil) -> String {
        let explicitPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitPassword.isEmpty {
            return explicitPassword
        }
        if let storedPassword = try? DarkgramEncryptionKeychainStore.shared.password(), let storedPassword, !storedPassword.isEmpty {
            return storedPassword
        }
        return self.defaultPassword
    }

    public static func hasCustomPassword() -> Bool {
        if let password = try? DarkgramEncryptionKeychainStore.shared.password(), let password {
            return !password.isEmpty
        }
        return false
    }

    public static func passwordStatusSuffix() -> String? {
        guard let password = try? DarkgramEncryptionKeychainStore.shared.password(), let password, !password.isEmpty else {
            return nil
        }
        return String(password.suffix(2))
    }

    public static func sanitizeTransportEntities(_ entities: [MessageTextEntity]?) -> [MessageTextEntity]? {
        guard let entities, !entities.isEmpty else {
            return nil
        }
        let filtered = entities.filter { entity in
            switch entity.type {
            case .CustomEmoji, .Custom:
                return false
            default:
                return true
            }
        }
        return filtered.isEmpty ? nil : filtered
    }

    public static func encryptText(_ text: String, entities: [MessageTextEntity]? = nil, password: String? = nil) throws -> String {
        guard !text.isEmpty else {
            throw DarkgramEncryptionError.emptyInput
        }

        let payload = DarkgramEncryptedContent(
            text: text,
            entities: self.sanitizeTransportEntities(entities)
        )
        let payloadData = try JSONEncoder().encode(payload)

        var cleartext = Data()
        cleartext.append(self.innerMagic)
        cleartext.append(self.encodeLength(payloadData.count))
        cleartext.append(payloadData)
        cleartext = self.pkcs7Pad(cleartext)

        let salt = try self.randomData(length: self.saltLength)
        let iv = try self.randomData(length: self.ivLength)
        let key = try self.deriveKey(password: self.resolvedPassword(password), salt: salt)

        guard let ciphertext = CryptoAES(true, key, iv, cleartext) else {
            throw DarkgramEncryptionError.encryptionFailed
        }

        var envelope = Data()
        envelope.append(self.outerMagic)
        envelope.append(self.version)
        envelope.append(salt)
        envelope.append(iv)
        envelope.append(ciphertext)
        return self.hexString(envelope)
    }

    public static func resolveText(_ text: String, password: String? = nil) -> DarkgramEncryptionResolvedText {
        guard self.looksLikePotentialEnvelope(text) else {
            return DarkgramEncryptionResolvedText(
                originalText: text,
                displayText: text,
                entities: nil,
                isEncryptedPayload: false,
                lockState: .none
            )
        }
        do {
            let content = try self.decryptContent(from: text, password: self.resolvedPassword(password))
            return DarkgramEncryptionResolvedText(
                originalText: text,
                displayText: content.text,
                entities: content.entities,
                isEncryptedPayload: true,
                lockState: .success
            )
        } catch DarkgramEncryptionError.invalidCiphertext {
            return DarkgramEncryptionResolvedText(
                originalText: text,
                displayText: text,
                entities: nil,
                isEncryptedPayload: false,
                lockState: .none
            )
        } catch {
            return DarkgramEncryptionResolvedText(
                originalText: text,
                displayText: text,
                entities: nil,
                isEncryptedPayload: true,
                lockState: .failure
            )
        }
    }

    private static func decryptContent(from text: String, password: String) throws -> DarkgramEncryptedContent {
        guard let envelope = self.dataFromHex(text) else {
            throw DarkgramEncryptionError.invalidCiphertext
        }
        let minimumLength = self.outerMagic.count + 1 + self.saltLength + self.ivLength + 16
        guard envelope.count >= minimumLength else {
            throw DarkgramEncryptionError.invalidCiphertext
        }
        guard envelope.prefix(self.outerMagic.count) == self.outerMagic else {
            throw DarkgramEncryptionError.invalidCiphertext
        }
        let versionOffset = self.outerMagic.count
        guard envelope[versionOffset] == self.version else {
            throw DarkgramEncryptionError.invalidCiphertext
        }

        let saltStart = versionOffset + 1
        let ivStart = saltStart + self.saltLength
        let ciphertextStart = ivStart + self.ivLength

        let salt = envelope.subdata(in: saltStart ..< ivStart)
        let iv = envelope.subdata(in: ivStart ..< ciphertextStart)
        let ciphertext = envelope.subdata(in: ciphertextStart ..< envelope.count)

        let key = try self.deriveKey(password: password, salt: salt)
        guard let paddedCleartext = CryptoAES(false, key, iv, ciphertext) else {
            throw DarkgramEncryptionError.invalidPayload
        }

        let cleartext = try self.pkcs7Unpad(paddedCleartext)
        guard cleartext.count >= self.innerMagic.count + 4 else {
            throw DarkgramEncryptionError.invalidPayload
        }
        guard cleartext.prefix(self.innerMagic.count) == self.innerMagic else {
            throw DarkgramEncryptionError.invalidPayload
        }

        let lengthStart = self.innerMagic.count
        let payloadLength = self.decodeLength(cleartext.subdata(in: lengthStart ..< (lengthStart + 4)))
        let payloadStart = lengthStart + 4
        guard cleartext.count >= payloadStart + payloadLength else {
            throw DarkgramEncryptionError.invalidPayload
        }

        let payloadData = cleartext.subdata(in: payloadStart ..< (payloadStart + payloadLength))
        let payload = try JSONDecoder().decode(DarkgramEncryptedContent.self, from: payloadData)
        return DarkgramEncryptedContent(text: payload.text, entities: self.sanitizeTransportEntities(payload.entities))
    }

    private static func deriveKey(password: String, salt: Data) throws -> Data {
        guard let passwordData = password.data(using: .utf8), let derived = MTPBKDF2(passwordData, salt, Int32(self.rounds)) else {
            throw DarkgramEncryptionError.keyDerivationFailed
        }
        return Data(derived.prefix(32))
    }

    private static func randomData(length: Int) throws -> Data {
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBytes in
            SecRandomCopyBytes(kSecRandomDefault, length, rawBytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw DarkgramEncryptionError.randomGenerationFailed(status)
        }
        return data
    }

    private static func pkcs7Pad(_ data: Data) -> Data {
        let blockSize = 16
        let remainder = data.count % blockSize
        let paddingCount = remainder == 0 ? blockSize : (blockSize - remainder)
        var result = data
        result.append(contentsOf: Array(repeating: UInt8(paddingCount), count: paddingCount))
        return result
    }

    private static func pkcs7Unpad(_ data: Data) throws -> Data {
        guard let padding = data.last, padding > 0, padding <= 16, data.count >= Int(padding) else {
            throw DarkgramEncryptionError.invalidPayload
        }
        let paddingCount = Int(padding)
        let tail = data.suffix(paddingCount)
        guard tail.allSatisfy({ $0 == padding }) else {
            throw DarkgramEncryptionError.invalidPayload
        }
        return Data(data.dropLast(paddingCount))
    }

    private static func encodeLength(_ value: Int) -> Data {
        let value32 = UInt32(clamping: value).bigEndian
        return withUnsafeBytes(of: value32) { Data($0) }
    }

    private static func decodeLength(_ data: Data) -> Int {
        return data.withUnsafeBytes { rawBytes in
            let value = rawBytes.load(as: UInt32.self)
            return Int(UInt32(bigEndian: value))
        }
    }

    private static func hexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func dataFromHex(_ string: String) -> Data? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count % 2 == 0 else {
            return nil
        }
        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index ..< nextIndex]
            guard let value = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(value)
            index = nextIndex
        }
        return data
    }

    private static func looksLikePotentialEnvelope(_ string: String) -> Bool {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 96, normalized.count % 2 == 0 else {
            return false
        }
        return normalized.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 70, 97 ... 102:
                return true
            default:
                return false
            }
        }
    }
}
