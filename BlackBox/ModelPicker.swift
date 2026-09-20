import SwiftUI

struct ModelPickerButton: View {
    @ObservedObject var agent: AgentSession
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(agent.provider.recommended.first { $0.id == agent.model }?.name ?? agent.model)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .disabled(agent.isBusy)
        .help("Choose a provider and model. Currently using \(agent.provider.name).")
        .accessibilityLabel("Choose model: \(agent.model), via \(agent.provider.name)")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(spacing: 0) {
                HStack {
                    Picker("Provider", selection: $agent.provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text("\(provider.name) — \(agent.configuredProviders.contains(provider) ? "Configured" : "Not configured")").tag(provider)
                        }
                    }.pickerStyle(.menu)
                    ProviderStatusLabel(configured: agent.configuredProviders.contains(agent.provider))
                }.padding(12)
                Divider()
                ModelPickerList(provider: agent.provider, selected: agent.model) { model in
                    guard !agent.isBusy else { return }
                    agent.model = model.id
                    isPresented = false
                }.id(agent.provider)
            }
            .onAppear { agent.refreshProviderConfiguration() }
        }
        .onChange(of: agent.isBusy) { _, busy in if busy { isPresented = false } }
    }
}

private struct ModelPickerList: View {
    @StateObject private var catalog: ModelCatalog
    let selected: String
    let choose: (OpenRouterModel) -> Void
    @State private var search = ""
    @State private var showAll = false
    @FocusState private var searchFocused: Bool

    init(provider: AIProvider, selected: String, choose: @escaping (OpenRouterModel) -> Void) {
        self.selected = selected
        self.choose = choose
        _catalog = StateObject(wrappedValue: ModelCatalog(provider: provider, fetchModels: {
            let key = provider == .openRouter ? nil : try KeychainStore.read(for: provider)
            return try await ProviderModelCatalogClient().fetch(provider: provider, key: key)
        }))
    }

    var body: some View {
        let choices = catalog.choices(selected: selected, search: search, showAll: showAll)
        let favorites = choices.filter { catalog.favorites.contains($0.id) }
        let recommended = choices.filter { choice in !catalog.favorites.contains(choice.id) && catalog.provider.recommended.contains(where: { $0.id == choice.id }) }
        let others = choices.filter { choice in !catalog.favorites.contains(choice.id) && !catalog.provider.recommended.contains(where: { $0.id == choice.id }) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(catalog.provider.name) models").font(.headline)
                Spacer()
                if catalog.isLoading { ProgressView().controlSize(.small) }
                Button {
                    Task { await catalog.refresh(force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(catalog.isLoading)
                    .help("Refresh model list").accessibilityLabel("Refresh model list")
            }.padding(14)
            TextField("Search models or providers", text: $search)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !favorites.isEmpty {
                        sectionTitle("Favorites")
                        ForEach(favorites) { model in row(model, isFavorite: true) }
                    }
                    if !recommended.isEmpty {
                        sectionTitle("Recommended")
                        ForEach(recommended) { model in row(model, isFavorite: false) }
                    }
                    if !others.isEmpty {
                        sectionTitle(catalog.provider != .openRouter ? "Available models" : (showAll ? "Other models" : "Current model"))
                        ForEach(others) { model in row(model, isFavorite: false) }
                    }
                    if choices.isEmpty {
                        Text("No matching models.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                }.padding(8)
            }
            Divider()
            if catalog.provider == .openRouter {
                Toggle("Show all compatible models", isOn: $showAll)
                    .toggleStyle(.checkbox).font(.caption).padding(.horizontal, 12).padding(.top, 10)
            } else {
                Text(catalog.provider == .openAI
                     ? "Five OpenAI models available in this picker."
                     : "Four Anthropic models available in this picker.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
            }
            if let error = catalog.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            Text("Star favorites to keep them at the top. Switch models anytime the assistant is idle.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 430, height: 480)
        .task { searchFocused = true; await catalog.refresh() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 5)
    }

    private func row(_ model: OpenRouterModel, isFavorite: Bool) -> some View {
        HStack(spacing: 4) {
            Button { if model.unavailableReason == nil { choose(model) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.id == selected ? "checkmark" : "cpu")
                        .foregroundStyle(model.id == selected ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(catalog.displayName(for: model.id)).font(.system(size: 12, weight: model.id == selected ? .semibold : .regular)).lineLimit(1)
                        Text(model.unavailableReason ?? catalog.provider.recommended.first { $0.id == model.id }?.role ?? model.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(8).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.unavailableReason != nil)
                .help(model.unavailableReason ?? "Use \(model.id)")
            Button { catalog.toggleFavorite(model.id) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 28, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel("\(isFavorite ? "Unstar" : "Star") \(model.name)")
        }
        .id("\(model.id)-\(isFavorite)")
        .padding(.trailing, 4)
        .background(model.id == selected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
