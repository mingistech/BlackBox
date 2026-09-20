import SwiftUI

struct ProviderStatusLabel: View {
    let configured: Bool
    var body: some View {
        Label(configured ? "Configured" : "Not configured", systemImage: configured ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(configured ? Color.green : Color.secondary)
    }
}

struct SettingsView: View {
    @ObservedObject var agent: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI Providers").font(.title2.weight(.semibold))
                Spacer()
                Text("\(agent.configuredProviders.count) of 3 configured").foregroundStyle(.secondary)
            }
            Text("Keys are stored separately in macOS Keychain. Choose which provider receives your chat and terminal context.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Use provider", selection: $agent.provider) {
                    ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
                }.disabled(agent.isBusy)
                ProviderStatusLabel(configured: agent.configuredProviders.contains(agent.provider))
            }
            HStack {
                TextField("Model ID for \(agent.provider.name)", text: $model)
                    .onSubmit(saveModel)
                    .disabled(agent.isBusy)
                Button("Use model", action: saveModel)
                    .disabled(agent.isBusy || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == agent.model)
            }
            Text("Current: \(agent.provider.name) · \(agent.model)").font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(spacing: 14) {
                ForEach(AIProvider.allCases) { provider in
                    ProviderKeyRow(agent: agent, provider: provider)
                }
            }.padding(.vertical, 2)
            Text("Configured means a key is saved. Test Connection verifies access using a short message with no terminal or chat content.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 570)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model = agent.model; agent.refreshProviderConfiguration() }
        .onChange(of: agent.provider) { _, _ in model = agent.model }
    }
    private func saveModel() {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !agent.isBusy else { return }
        agent.model = value
        model = value
    }
}

private struct ProviderKeyRow: View {
    @ObservedObject var agent: AgentSession
    let provider: AIProvider
    @State private var apiKey = ""
    @State private var message: String?
    @State private var succeeded = false
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    private var configured: Bool { agent.configuredProviders.contains(provider) }
    private var entered: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider == .anthropic ? "Anthropic · Claude" : provider.name).font(.headline)
                Spacer()
                ProviderStatusLabel(configured: configured)
            }
            Text(configured ? "API key saved in Keychain." : "Add your \(provider.name) API key to use this provider.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField(configured ? "Enter a replacement API key" : "\(provider.name) API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isTesting)
                .onChange(of: apiKey) { _, _ in message = nil; succeeded = false }
            HStack {
                Button("Save key", action: saveKey).disabled(entered.isEmpty || isTesting || agent.isBusy)
                Button(isTesting ? "Testing…" : "Test Connection", action: testConnection)
                    .disabled(isTesting || agent.isBusy || (!configured && entered.isEmpty))
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                if configured {
                    Button("Remove key", role: .destructive, action: removeKey).disabled(isTesting || agent.isBusy)
                }
            }
            if let error = agent.providerErrors[provider] {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let message {
                Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(succeeded ? Color.green : Color.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onDisappear { testTask?.cancel() }
    }
    private func saveKey() {
        do {
            try KeychainStore.save(entered, for: provider)
            apiKey = ""
            agent.refreshProviderConfiguration()
            succeeded = false
            message = nil
        } catch { succeeded = false; message = error.localizedDescription }
    }
    private func removeKey() {
        do {
            try KeychainStore.delete(for: provider)
            apiKey = ""
            agent.refreshProviderConfiguration()
            message = nil
            succeeded = false
        } catch { succeeded = false; message = error.localizedDescription }
    }
    private func testConnection() {
        let key: String
        let testingUnsavedKey = !entered.isEmpty
        do {
            key = try entered.isEmpty ? (KeychainStore.read(for: provider) ?? "") : entered
            guard !key.isEmpty else { message = "Enter an API key first."; return }
        } catch { succeeded = false; message = error.localizedDescription; return }
        let model = agent.provider == provider ? agent.model : provider.selectedModel()
        isTesting = true
        message = nil
        testTask = Task { @MainActor in
            defer { isTesting = false }
            do {
                _ = try await ModelClient().complete(provider: provider, key: key, model: model,
                    messages: [APIMessage(role: "user", content: "Connection test. Reply OK without calling tools.")], mode: .ask)
                try Task.checkCancellation()
                succeeded = true
                message = "Connection verified with \(model)." + (testingUnsavedKey ? " Save key to configure this provider." : "")
            } catch {
                if !Task.isCancelled { succeeded = false; message = error.localizedDescription }
            }
        }
    }
}
