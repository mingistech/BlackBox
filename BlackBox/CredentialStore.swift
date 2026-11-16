import Foundation
import Combine

@MainActor
final class CredentialStore: ObservableObject {
    static let shared = CredentialStore()
    @Published private(set) var vaultURL: URL?
    @Published private(set) var isUnlocked = false
    @Published private(set) var revision = 0
    private var unlocked: PortableVault.Unlocked?
    private var diskData: Data?
    var usesPortableKeys: Bool { vaultURL != nil }
    var suggestedURL: URL { Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(PortableVault.filename) }

    private init() {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(PortableVault.filename)
        if FileManager.default.fileExists(atPath: sibling.path) { vaultURL = sibling }
    }
    func useKeychain() {
        lock()
        vaultURL = nil
        changed()
    }
    func select(_ url: URL) {
        lock()
        vaultURL = url
        changed()
    }
    func lock() {
        unlocked = nil
        diskData = nil
        isUnlocked = false
        changed()
    }
    func unlock(passphrase: String) async throws {
        guard let url = vaultURL else { return }
        let data = try readFile(url)
        let result = try await Task.detached { try PortableVault.unlock(data, passphrase: passphrase) }.value
        guard vaultURL == url else { return }
        unlocked = result
        diskData = data
        isUnlocked = true
        changed()
    }
    func create(at url: URL, passphrase: String, copySavedKeys: Bool) async throws {
        guard url.lastPathComponent == PortableVault.filename else {
            throw AppError.message("Name the file BlackBox.keys so BlackBox can find it at launch.")
        }
        guard !url.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
            throw AppError.message("Save portable keys outside the application bundle.")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw AppError.message("A file already exists there. Open it instead of replacing it.") }
        var keys: [String: String] = [:]
        if copySavedKeys {
            for provider in AIProvider.allCases { if let value = try KeychainStore.read(for: provider) { keys[provider.rawValue] = value } }
        }
        let result = try await Task.detached { try PortableVault.create(passphrase: passphrase, keys: keys) }.value
        // Exclusive creation avoids overwriting an existing vault, including another app instance's file.
        try result.1.write(to: url, options: .withoutOverwriting)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        vaultURL = url
        unlocked = result.0
        diskData = result.1
        isUnlocked = true
        changed()
    }
    func containsKey(for provider: AIProvider) throws -> Bool {
        guard usesPortableKeys else { return try KeychainStore.containsKey(for: provider) }
        guard isUnlocked else { return false }
        return try read(for: provider) != nil
    }
    func read(for provider: AIProvider) throws -> String? {
        guard let url = vaultURL else { return try KeychainStore.read(for: provider) }
        guard let unlocked else { throw AppError.message("Unlock portable keys in Settings before using the assistant.") }
        guard try readFile(url) == diskData else { throw AppError.message("The portable key file changed. Lock and unlock it again before continuing.") }
        return unlocked.keys[provider.rawValue]
    }
    func save(_ value: String, for provider: AIProvider) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Enter a nonempty API key.") }
        if usesPortableKeys { try update(value, for: provider) }
        else { try KeychainStore.save(value, for: provider) }
        changed()
    }
    func delete(for provider: AIProvider) throws {
        if usesPortableKeys { try update(nil, for: provider) }
        else { try KeychainStore.delete(for: provider) }
        changed()
    }
    private func update(_ value: String?, for provider: AIProvider) throws {
        _ = try read(for: provider)
        guard let url = vaultURL, var candidate = unlocked else { return }
        candidate.keys[provider.rawValue] = value
        let encrypted = try PortableVault.encode(candidate)
        try encrypted.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        unlocked = candidate
        diskData = encrypted
    }
    private func readFile(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 128_000 else {
            throw AppError.message("Choose a regular BlackBox portable key file.")
        }
        return try Data(contentsOf: url)
    }
    private func changed() {
        for provider in AIProvider.allCases { UserDefaults.standard.removeObject(forKey: provider.modelCatalogCacheKey) }
        revision += 1
    }
}
