import CryptoKit
import Foundation

enum ProfileEncryptionError: LocalizedError {
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidEnvelope

    var errorDescription: String? {
        switch self {
        case .encryptionFailed(let message):
            "Failed to encrypt connection profiles: \(message)"
        case .decryptionFailed(let message):
            "Failed to decrypt connection profiles: \(message)"
        case .invalidEnvelope:
            "Connection profile store has an unsupported or corrupt encrypted format."
        }
    }
}

struct EncryptedProfilesEnvelope: Codable, Equatable, Sendable {
    static let formatIdentifier = "dockbridge-profiles-v1"

    let format: String
    let payload: Data

    init(payload: Data) {
        format = Self.formatIdentifier
        self.payload = payload
    }
}

final class ProfileEncryptionService: @unchecked Sendable {
    static let masterKeyAccount = "profiles.master-key"

    private let keychain: KeychainService

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain
    }

    func encrypt(_ profiles: [StoredConnectionProfile]) throws -> EncryptedProfilesEnvelope {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext: Data
        do {
            plaintext = try encoder.encode(profiles)
        } catch {
            throw ProfileEncryptionError.encryptionFailed(error.localizedDescription)
        }

        do {
            let key = try loadOrCreateMasterKey()
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                throw ProfileEncryptionError.encryptionFailed("AES-GCM seal returned no combined payload.")
            }
            return EncryptedProfilesEnvelope(payload: combined)
        } catch let error as ProfileEncryptionError {
            throw error
        } catch {
            throw ProfileEncryptionError.encryptionFailed(error.localizedDescription)
        }
    }

    func decrypt(_ envelope: EncryptedProfilesEnvelope) throws -> [StoredConnectionProfile] {
        guard envelope.format == EncryptedProfilesEnvelope.formatIdentifier else {
            throw ProfileEncryptionError.invalidEnvelope
        }

        do {
            let key = try requireMasterKey()
            let sealed = try AES.GCM.SealedBox(combined: envelope.payload)
            let plaintext = try AES.GCM.open(sealed, using: key)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([StoredConnectionProfile].self, from: plaintext)
        } catch let error as ProfileEncryptionError {
            throw error
        } catch {
            throw ProfileEncryptionError.decryptionFailed(error.localizedDescription)
        }
    }

    private func loadOrCreateMasterKey() throws -> SymmetricKey {
        if let existing = try keychain.loadKeyData(account: Self.masterKeyAccount) {
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keychain.saveKeyData(keyData, account: Self.masterKeyAccount)
        return key
    }

    private func requireMasterKey() throws -> SymmetricKey {
        guard let existing = try keychain.loadKeyData(account: Self.masterKeyAccount) else {
            throw ProfileEncryptionError.decryptionFailed(
                "Master encryption key is missing from Keychain."
            )
        }
        return SymmetricKey(data: existing)
    }
}
