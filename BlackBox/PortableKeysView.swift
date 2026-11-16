import SwiftUI
import UniformTypeIdentifiers

struct PortableKeysView: View {
    @ObservedObject private var store = CredentialStore.shared
    @ObservedObject var agent: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var copySaved = false
    @State private var creating = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Portable API Keys").font(.title2.weight(.semibold))
            Text("Keep BlackBox.app and BlackBox.keys together on your SSD. Your keys are encrypted with a passphrase that you enter each launch. Keep a backup: a lost passphrase cannot be recovered.")
                .font(.callout).foregroundStyle(.secondary)
            if store.usesPortableKeys, !creating {
                Label(store.isUnlocked ? "Portable keys unlocked" : "Portable keys locked",
                      systemImage: store.isUnlocked ? "lock.open.fill" : "lock.fill")
                Text(store.vaultURL?.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if store.isUnlocked {
                    Text("Provider keys added or removed in Settings are saved in this encrypted file.").font(.callout)
                    Button("Lock portable keys") { store.lock(); agent.refreshProviderConfiguration() }
                } else {
                    SecureField("Passphrase", text: $passphrase).onSubmit(unlock)
                    Button("Unlock", action: unlock).disabled(passphrase.isEmpty)
                }
            } else if creating {
                SecureField("New passphrase (at least 8 characters)", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
                Toggle("Copy this Mac’s saved provider keys into the portable file", isOn: $copySaved)
                    .font(.callout)
                Text("Existing Keychain keys stay on this Mac. The portable passphrase is never saved.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { creating = false; clearSecrets() }
                    Button("Choose Location and Create…", action: create)
                        .disabled(passphrase.count < 8 || passphrase != confirmation)
                }
            } else {
                Label("Using this Mac’s Keychain", systemImage: "key.fill")
            }
            if working { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                Button("Open Key File…", action: open)
                Button("Create Portable Keys…") { creating = true; clearSecrets(); error = nil }
            }
            if store.usesPortableKeys {
                Button("Use Keychain for This Session") { store.useKeychain(); agent.refreshProviderConfiguration(); clearSecrets() }
                    .help("The portable file stays on your SSD and will be detected again next launch.")
            }
            Text("If macOS opens the app from a temporary location, use Open Key File to select BlackBox.keys on your SSD. Each Mac must meet BlackBox’s system requirements.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { clearSecrets(); dismiss() } }
        }
        .padding(24).frame(width: 540)
        .disabled(working || agent.isBusy)
        .onDisappear { clearSecrets() }
    }
    private func clearSecrets() { passphrase = ""; confirmation = "" }
    private func unlock() {
        guard !working, !agent.isBusy else { return }
        working = true; error = nil
        let password = passphrase
        clearSecrets()
        Task { @MainActor in
            defer { working = false }
            do { try await store.unlock(passphrase: password); agent.refreshProviderConfiguration() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func open() {
        let panel = NSOpenPanel()
        panel.title = "Open BlackBox Portable Keys"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.suggestedURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.select(url); creating = false; error = nil; clearSecrets()
        agent.refreshProviderConfiguration()
    }
    private func create() {
        guard !working, !agent.isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Save Portable Keys Beside BlackBox.app"
        panel.nameFieldStringValue = PortableVault.filename
        panel.directoryURL = store.suggestedURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Never let a save panel choice target files inside the signed application.
        guard !url.pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
            error = "Save the file beside the app, outside the app bundle."; return
        }
        working = true; error = nil
        let password = passphrase
        let copy = copySaved
        clearSecrets()
        Task { @MainActor in
            defer { working = false }
            do {
                try await store.create(at: url, passphrase: password, copySavedKeys: copy)
                creating = false; agent.refreshProviderConfiguration()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct PortableLaunchPresenter: ViewModifier {
    @ObservedObject var agent: AgentSession
    @ObservedObject private var store = CredentialStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var checked = false
    func body(content: Content) -> some View {
        content.onAppear {
            guard !checked else { return }
            checked = true
            #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
            #endif
            if store.usesPortableKeys && !store.isUnlocked { openWindow(id: "portable-keys") }
        }
        .onChange(of: store.revision) { _, _ in agent.refreshProviderConfiguration() }
    }
}
