import XCTest
@testable import BlackBoxCore

final class ModelCatalogTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let name = "BlackBoxModelCatalogTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private static let alpha = OpenRouterModel(id: "example/alpha", name: "Alpha", supported_parameters: ["tools", "tool_choice"])
    private static let zeta = OpenRouterModel(id: "example/zeta", name: "Zeta", supported_parameters: ["tools", "tool_choice"])

    @MainActor func testFavoritesSortFirstAndPersistIndependentlyOfSelection() async {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = ModelCatalog(defaults: defaults, fetchModels: { [Self.alpha, Self.zeta] })
        await catalog.refresh()
        catalog.toggleFavorite(Self.zeta.id)
        XCTAssertEqual(catalog.choices(selected: Self.alpha.id, search: "").first?.id, Self.zeta.id)
        let reopened = ModelCatalog(defaults: defaults)
        XCTAssertTrue(reopened.favorites.contains(Self.zeta.id))
        XCTAssertEqual(reopened.displayName(for: Self.zeta.id), "Zeta")
        reopened.toggleFavorite(Self.zeta.id)
        XCTAssertFalse(ModelCatalog(defaults: defaults).favorites.contains(Self.zeta.id))
    }

    @MainActor func testSearchMatchesNameAndProviderAndPreservesCustomSelection() async {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = ModelCatalog(defaults: defaults, fetchModels: { [Self.alpha, Self.zeta] })
        await catalog.refresh()
        XCTAssertEqual(catalog.choices(selected: "custom/my-model", search: "  ALPHA  ", showAll: true).map(\.id), [Self.alpha.id])
        XCTAssertEqual(catalog.choices(selected: "custom/my-model", search: "EXAMPLE/", showAll: true).count, 2)
        XCTAssertEqual(catalog.choices(selected: "custom/my-model", search: "my-model").first?.id, "custom/my-model")
        XCTAssertTrue(catalog.choices(selected: Self.alpha.id, search: "no such model").isEmpty)
    }

    @MainActor func testFilteringAllowsImplicitToolChoiceAndExcludesNonTextModels() async throws {
        let data = Data(#"[{"id":"example/good","name":"Good","supported_parameters":["tools","tool_choice"],"architecture":{"output_modalities":["text"]}},{"id":"example/no-choice","name":"Missing choice","supported_parameters":["tools"]},{"id":"example/image","name":"Image","supported_parameters":["tools","tool_choice"],"architecture":{"output_modalities":["image"]}}]"#.utf8)
        let models = try JSONDecoder().decode([OpenRouterModel].self, from: data)
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = ModelCatalog(defaults: defaults, fetchModels: { models })
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["example/good", "example/no-choice"])
    }

    @MainActor func testFailedRefreshKeepsCachedModelsAndDelistedFavorites() async {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = ModelCatalog(defaults: defaults, fetchModels: { [Self.alpha] })
        await original.refresh()
        original.toggleFavorite("old/favorite")
        let offline = ModelCatalog(defaults: defaults, fetchModels: { throw URLError(.notConnectedToInternet) })
        await offline.refresh(force: true)
        XCTAssertNotNil(offline.error)
        XCTAssertFalse(offline.isLoading)
        XCTAssertEqual(offline.models.map(\.id), [Self.alpha.id])
        XCTAssertEqual(offline.choices(selected: Self.alpha.id, search: "").first?.id, "old/favorite")
    }
    @MainActor func testShortlistDefaultsToQwenAndFullCatalogIsOptional() async {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = ModelCatalog(defaults: defaults, fetchModels: { [Self.alpha, Self.zeta] })
        await catalog.refresh()
        XCTAssertEqual(RecommendedModels.selectedModel(defaults: defaults), "qwen/qwen3-coder")
        XCTAssertEqual(catalog.choices(selected: RecommendedModels.defaultID, search: "").map(\.id), RecommendedModels.all.map(\.id))
        XCTAssertEqual(catalog.choices(selected: RecommendedModels.defaultID, search: "", showAll: true).count, 6)
        catalog.toggleFavorite(Self.zeta.id)
        XCTAssertEqual(catalog.choices(selected: RecommendedModels.defaultID, search: "").first?.id, Self.zeta.id)
        defaults.set(Self.alpha.id, forKey: "openRouterModel")
        XCTAssertEqual(RecommendedModels.selectedModel(defaults: defaults), Self.alpha.id)
        defaults.set("  ", forKey: "openRouterModel")
        XCTAssertEqual(RecommendedModels.selectedModel(defaults: defaults), RecommendedModels.defaultID)
    }

}
