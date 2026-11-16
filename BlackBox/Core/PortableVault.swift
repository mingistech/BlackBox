import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Portable, authenticated encryption. The passphrase and derived key are never written to disk.
enum PortableVault {
    static let filename = "BlackBox.keys"
    static let rounds = 600_000
    struct Envelope: Codable {
        let version: Int
        let salt: Data
        let rounds: Int
        let sealed: Data
    }
    struct Unlocked {
        let key: SymmetricKey
        let salt: Data
        var keys: [String: String]
    }
    static func create(passphrase: String, keys: [String: String]) throws -> (Unlocked, Data) {
        guard passphrase.count >= 8 else { throw AppError.message("Use a passphrase with at least 8 characters.") }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppError.message("Could not generate encryption salt.") }
        let unlocked = Unlocked(key: try derive(passphrase, salt: salt), salt: salt, keys: keys)
        return (unlocked, try encode(unlocked))
    }
    static func unlock(_ data: Data, passphrase: String) throws -> Unlocked {
        guard data.count < 128_000 else { throw AppError.message("This portable key file is too large.") }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw AppError.message("This is not a valid BlackBox portable key file.") }
        guard envelope.version == 1, envelope.rounds == rounds, envelope.salt.count == 16 else {
            throw AppError.message("This portable key file uses an unsupported format.")
        }
        let key = try derive(passphrase, salt: envelope.salt)
        do {
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key,
                                         authenticating: Data("BlackBox portable keys v1".utf8))
            let keys = try JSONDecoder().decode([String: String].self, from: clear)
            return Unlocked(key: key, salt: envelope.salt, keys: keys)
        } catch { throw AppError.message("Couldn’t unlock the key file. Check the passphrase and that the file is intact.") }
    }
    static func encode(_ unlocked: Unlocked) throws -> Data {
        let clear = try JSONEncoder().encode(unlocked.keys)
        let box = try AES.GCM.seal(clear, using: unlocked.key, authenticating: Data("BlackBox portable keys v1".utf8))
        let data = try JSONEncoder().encode(Envelope(version: 1, salt: unlocked.salt, rounds: rounds, sealed: box.combined!))
        guard data.count < 128_000 else { throw AppError.message("The portable keys exceed the file size limit.") }
        return data
    }
    private static func derive(_ passphrase: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard !passphrase.isEmpty else { throw AppError.message("Enter the portable key passphrase.") }
        let password = Array(passphrase.utf8)
        let status = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                    saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &bytes, bytes.count)
            }
        }
        guard status == kCCSuccess else { throw AppError.message("Could not derive the encryption key.") }
        return SymmetricKey(data: bytes)
    }
}
