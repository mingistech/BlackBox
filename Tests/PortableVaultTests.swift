import XCTest
@testable import BlackBoxCore

final class PortableVaultTests: XCTestCase {
    func testEncryptedRoundTripAndKeyChanges() throws {
        let secret = "fixture-private-api-key"
        let (unlocked, data) = try PortableVault.create(passphrase: "a long test passphrase", keys: ["openAI": secret])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        var reopened = try PortableVault.unlock(data, passphrase: "a long test passphrase")
        XCTAssertEqual(reopened.keys, ["openAI": secret])
        reopened.keys["anthropic"] = "fixture-second-key"
        reopened.keys["openAI"] = nil
        let updated = try PortableVault.encode(reopened)
        XCTAssertEqual(try PortableVault.unlock(updated, passphrase: "a long test passphrase").keys, ["anthropic": "fixture-second-key"])
        XCTAssertNotEqual(try PortableVault.encode(unlocked), data) // fresh nonce on every save
    }
    func testWrongPasswordTamperingAndUnsupportedFormatsFail() throws {
        let (_, data) = try PortableVault.create(passphrase: "another long passphrase", keys: [:])
        XCTAssertThrowsError(try PortableVault.unlock(data, passphrase: "wrong password"))
        XCTAssertThrowsError(try PortableVault.unlock(data, passphrase: ""))
        let envelope = try JSONDecoder().decode(PortableVault.Envelope.self, from: data)
        var corrupted = envelope.sealed
        corrupted[corrupted.count - 1] ^= 1
        let tampered = PortableVault.Envelope(version: 1, salt: envelope.salt, rounds: PortableVault.rounds, sealed: corrupted)
        XCTAssertThrowsError(try PortableVault.unlock(JSONEncoder().encode(tampered), passphrase: "another long passphrase"))
        let excessive = PortableVault.Envelope(version: 1, salt: envelope.salt, rounds: Int.max, sealed: envelope.sealed)
        XCTAssertThrowsError(try PortableVault.unlock(JSONEncoder().encode(excessive), passphrase: "another long passphrase"))
        XCTAssertThrowsError(try PortableVault.unlock(Data(repeating: 0, count: 128_000), passphrase: "password"))
        XCTAssertThrowsError(try PortableVault.create(passphrase: "1234567", keys: [:]))
        let (_, minimum) = try PortableVault.create(passphrase: "12345678", keys: [:])
        XCTAssertNoThrow(try PortableVault.unlock(minimum, passphrase: "12345678"))
    }
}
