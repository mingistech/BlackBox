import XCTest
@testable import BlackBoxCore

private final class CatalogURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, result) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ProviderCatalogTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogURLProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() { session.invalidateAndCancel(); CatalogURLProtocol.handler = nil }

    func testOpenAICatalogUsesSavedKeyAndIncludesEveryModel() async throws {
        CatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-openai")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            return (200, ["data": [["id": "gpt-6-astra"], ["id": "gpt-4.1"], ["id": "gpt-image-1"], ["id": "text-embedding-3-small"], ["id": "new-future-model"]]])
        }
        let models = try await ProviderModelCatalogClient(session: session).fetch(provider: .openAI, key: "fixture-openai")
        XCTAssertEqual(models.count, 5)
        XCTAssertNotNil(models.first { $0.id == "gpt-image-1" }?.unavailableReason)
        XCTAssertNotNil(models.first { $0.id == "text-embedding-3-small" }?.unavailableReason)
        XCTAssertNil(models.first { $0.id == "new-future-model" }?.unavailableReason)
    }

    func testAnthropicPaginationPreservesNamesAndDeduplicates() async throws {
        var requests = 0
        CatalogURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-anthropic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "1000")
            if requests == 1 {
                XCTAssertNil(query?.first { $0.name == "after_id" })
                return (200, ["data": [["id": "claude-sonnet-5", "display_name": "Claude Sonnet 5"]], "has_more": true, "last_id": "claude-sonnet-5"])
            }
            XCTAssertEqual(query?.first { $0.name == "after_id" }?.value, "claude-sonnet-5")
            return (200, ["data": [["id": "claude-opus-5", "display_name": "Claude Opus 5"], ["id": "claude-sonnet-5", "display_name": "Claude Sonnet 5"]], "has_more": false])
        }
        let models = try await ProviderModelCatalogClient(session: session).fetch(provider: .anthropic, key: "fixture-anthropic")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first { $0.id == "claude-opus-5" }?.name, "Claude Opus 5")
    }

    func testRepeatedPaginationCursorFailsInsteadOfLoopingForever() async {
        var requests = 0
        CatalogURLProtocol.handler = { _ in
            requests += 1
            return (200, ["data": [["id": "claude-test"]], "has_more": true, "last_id": "same-cursor"])
        }
        do {
            _ = try await ProviderModelCatalogClient(session: session).fetch(provider: .anthropic, key: "fixture")
            XCTFail("Expected invalid cursor error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("pagination")) }
        XCTAssertEqual(requests, 2)
    }

    @MainActor func testOpenAIShortlistExcludesCachedSelectedAndStarredExtras() async {
        let suite = "OpenAIShortlistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
        let models = [OpenRouterModel(id: "gpt-6-astra", name: "Astra"), OpenRouterModel(id: "gpt-4.1-mini", name: "Mini")]
        let catalog = ModelCatalog(defaults: defaults, provider: .openAI, fetchModels: { models })
        XCTAssertEqual(catalog.choices(selected: "gpt-6-astra", search: "").map(\.id), expected)
        await catalog.refresh()
        catalog.toggleFavorite("gpt-4.1-mini")
        XCTAssertEqual(catalog.choices(selected: "gpt-4.1-mini", search: "", showAll: true).map(\.id), expected)
        catalog.toggleFavorite("gpt-5.6-luna")
        let starredOrder = ["gpt-5.6-luna"] + expected.filter { $0 != "gpt-5.6-luna" }
        XCTAssertEqual(catalog.choices(selected: "gpt-6-astra", search: "").map(\.id), starredOrder)
        XCTAssertEqual(catalog.choices(selected: "gpt-6-astra", search: "terra").map(\.id), ["gpt-5.6-terra"])
        let offline = ModelCatalog(defaults: defaults, provider: .openAI, fetchModels: { throw URLError(.notConnectedToInternet) })
        await offline.refresh()
        XCTAssertNotNil(offline.error)
        XCTAssertEqual(offline.choices(selected: "custom-model", search: "").map(\.id), starredOrder)
        XCTAssertTrue(offline.choices(selected: "custom-model", search: "custom").isEmpty)
    }

    @MainActor func testAnthropicShortlistExcludesExtrasAndCachesSeparatelyWithFavoritesFirst() async {
        let suite = "NativeCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = [OpenRouterModel(id: "claude-sonnet-5", name: "Sonnet"), OpenRouterModel(id: "claude-other", name: "Other")]
        let catalog = ModelCatalog(defaults: defaults, provider: .anthropic, fetchModels: { models })
        let expected = ["claude-sonnet-5", "claude-fable-5-1", "claude-opus-5", "claude-haiku-4-5"]
        XCTAssertEqual(catalog.choices(selected: "claude-sonnet-5", search: "").map(\.id), expected)
        await catalog.refresh()
        catalog.toggleFavorite("claude-other")
        XCTAssertEqual(catalog.choices(selected: "claude-other", search: "", showAll: true).map(\.id), expected)
        catalog.toggleFavorite("claude-haiku-4-5")
        XCTAssertEqual(catalog.choices(selected: "claude-sonnet-5", search: "").map(\.id), ["claude-haiku-4-5", "claude-sonnet-5", "claude-fable-5-1", "claude-opus-5"])
        let offline = ModelCatalog(defaults: defaults, provider: .anthropic, fetchModels: { throw URLError(.notConnectedToInternet) })
        await offline.refresh()
        XCTAssertNotNil(offline.error)
        XCTAssertEqual(offline.models, models)
        XCTAssertTrue(ModelCatalog(defaults: defaults, provider: .openAI).models.isEmpty)
        XCTAssertTrue(offline.choices(selected: "custom-model", search: "custom").isEmpty)
        XCTAssertEqual(offline.choices(selected: "custom-model", search: "").map(\.id), ["claude-haiku-4-5", "claude-sonnet-5", "claude-fable-5-1", "claude-opus-5"])
        XCTAssertEqual(offline.choices(selected: "claude-sonnet-5", search: "fable").map(\.id), ["claude-fable-5-1"])
    }

    func testMissingKeyDoesNotSendRequestAndProviderErrorDoesNotLeakData() async {
        CatalogURLProtocol.handler = { _ in XCTFail("Missing key must not send a request"); return (200, ["data": []]) }
        do {
            _ = try await ProviderModelCatalogClient(session: session).fetch(provider: .openAI)
            XCTFail("Expected missing key error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
        CatalogURLProtocol.handler = { _ in (401, ["error": ["message": "SECRET-fixture"]]) }
        do {
            _ = try await ProviderModelCatalogClient(session: session).fetch(provider: .openAI, key: "fixture")
            XCTFail("Expected rejected key")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("key was rejected"))
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
    }
}
