import Combine
import Foundation

struct OpenRouterModel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    var supported_parameters: [String]?
    var architecture: Architecture?
    var unavailableReason: String?

    struct Architecture: Codable, Equatable {
        var output_modalities: [String]?
    }

    var supportsAgent: Bool {
        let parameters = Set(supported_parameters ?? [])
        return parameters.contains("tools")
            && (architecture?.output_modalities?.contains("text") ?? true)
    }

    static func saved(_ id: String) -> Self {
        Self(id: id, name: RecommendedModels.find(id)?.name ?? id)
    }
}

@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var models: [OpenRouterModel]
    @Published private(set) var favorites: Set<String>
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    let provider: AIProvider
    private let defaults: UserDefaults
    private let fetchModels: () async throws -> [OpenRouterModel]
    private var lastRefresh: Date?
    private var favoritesKey: String { provider == .openRouter ? "openRouterFavoriteModels" : "\(provider.rawValue)FavoriteModels" }


    init(defaults: UserDefaults = .standard, provider: AIProvider = .openRouter,
         fetchModels: (() async throws -> [OpenRouterModel])? = nil) {
        self.defaults = defaults
        self.provider = provider
        self.fetchModels = fetchModels ?? { try await ProviderModelCatalogClient().fetch(provider: provider) }
        favorites = Set(defaults.stringArray(forKey: provider == .openRouter ? "openRouterFavoriteModels" : "\(provider.rawValue)FavoriteModels") ?? [])
        models = defaults.data(forKey: provider.modelCatalogCacheKey)
            .flatMap { try? JSONDecoder().decode([OpenRouterModel].self, from: $0) } ?? []
    }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) }
        else { favorites.insert(id) }
        defaults.set(favorites.sorted(), forKey: favoritesKey)
    }

    func displayName(for id: String) -> String {
        provider.recommended.first { $0.id == id }?.name ?? models.first { $0.id == id }?.name ?? id
    }

    func choices(selected: String, search: String, showAll: Bool = false) -> [OpenRouterModel] {
        var byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recommendedIDs = Set(provider.recommended.map(\.id))
        let visibleIDs = favorites.union(recommendedIDs).union([selected])
        // Keep selected/custom and starred models reachable when offline or delisted.
        for id in visibleIDs where byID[id] == nil {
            byID[id] = OpenRouterModel(id: id, name: displayName(for: id))
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return byID.values.filter { choice in
            (provider == .openRouter || recommendedIDs.contains(choice.id)) &&
            (provider != .openRouter || showAll || visibleIDs.contains(choice.id)) &&
                (query.isEmpty || choice.name.localizedCaseInsensitiveContains(query) || choice.id.localizedCaseInsensitiveContains(query)
                 || (provider.recommended.first(where: { model in model.id == choice.id })?.role.localizedCaseInsensitiveContains(query) ?? false))
        }.sorted { left, right in
            let leftStar = favorites.contains(left.id)
            let rightStar = favorites.contains(right.id)
            if leftStar != rightStar { return leftStar }
            let leftRank = provider.recommended.firstIndex { $0.id == left.id } ?? Int.max
            let rightRank = provider.recommended.firstIndex { $0.id == right.id } ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 3600 { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fetched = try await fetchModels()
            try Task.checkCancellation()
            let usable = provider == .openRouter ? fetched.filter(\.supportsAgent) : fetched
            guard provider != .openRouter || !usable.isEmpty else { throw AppError.message("No tool-capable models were returned.") }
            models = usable
            defaults.set(try JSONEncoder().encode(usable), forKey: provider.modelCatalogCacheKey)
            lastRefresh = Date()
        } catch is CancellationError {
            // Closing the popover cancels its fetch; retry the next time it opens.
        } catch {
            if !Task.isCancelled { self.error = "Couldn’t refresh models. Saved choices are still available. \(error.localizedDescription)" }
        }
    }

}
