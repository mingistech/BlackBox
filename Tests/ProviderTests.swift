import XCTest
@testable import BlackBoxCore

private final class ProviderURLProtocol: URLProtocol {
    static var handler: ((URLRequest, [String: Any]) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(bytes, count: count)
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let (status, response) = try Self.handler!(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ProviderTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderURLProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        ProviderURLProtocol.handler = nil
    }
    private var client: ModelClient { ModelClient(session: session) }

    func testExistingRouterPreferencesAndSeparateProviderModels() {
        let name = "ProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AIProvider.selected(defaults: defaults), .openRouter)
        XCTAssertEqual(AIProvider.openRouter.selectedModel(defaults: defaults), "qwen/qwen3-coder")
        defaults.set("custom/router", forKey: "openRouterModel")
        defaults.set("openAI", forKey: "aiProvider")
        XCTAssertEqual(AIProvider.selected(defaults: defaults), .openAI)
        XCTAssertEqual(AIProvider.openAI.selectedModel(defaults: defaults), "gpt-6-astra")
        XCTAssertEqual(AIProvider.anthropic.selectedModel(defaults: defaults), "claude-sonnet-5")
        XCTAssertEqual(AIProvider.openRouter.selectedModel(defaults: defaults), "custom/router")
        XCTAssertEqual(AIProvider.openRouter.keychainService, "BlackBox.OpenRouter")
        XCTAssertEqual(Set(AIProvider.allCases.map(\.keychainService)).count, 3)
    }

    @MainActor func testCatalogAndFavoritesStayWithTheirProvider() async {
        let name = "ProviderCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let router = ModelCatalog(defaults: defaults)
        router.toggleFavorite("openai/gpt-6-astra")
        let direct = ModelCatalog(defaults: defaults, provider: .openAI, fetchModels: { [OpenRouterModel(id: "gpt-6-astra", name: "Astra"), OpenRouterModel(id: "gpt-4.1", name: "GPT 4.1")] })
        await direct.refresh()
        XCTAssertTrue(direct.favorites.isEmpty)
        XCTAssertEqual(direct.choices(selected: "gpt-6-astra", search: "").map(\.id), ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        direct.toggleFavorite("gpt-6-astra")
        XCTAssertEqual(router.favorites, ["openai/gpt-6-astra"])
        XCTAssertEqual(ModelCatalog(defaults: defaults, provider: .openAI).favorites, ["gpt-6-astra"])
        XCTAssertEqual(ModelCatalog(defaults: defaults, provider: .anthropic).choices(selected: "claude-sonnet-5", search: "").map(\.id), ["claude-sonnet-5", "claude-fable-5-1", "claude-opus-5", "claude-haiku-4-5"])
    }

    func testOpenAIResponsesRoundTripPreservesEncryptedReasoningAndCallID() async throws {
        var count = 0
        ProviderURLProtocol.handler = { request, body in
            count += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-test")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 5)
            XCTAssertEqual(tools.first?["type"] as? String, "function")
            XCTAssertEqual(tools.first?["strict"] as? Bool, false)
            if count == 1 {
                return (200, ["status": "completed", "output": [
                    ["type": "reasoning", "id": "rs_test", "summary": [], "encrypted_content": "opaque-openai"],
                    ["type": "function_call", "id": "fc_item", "call_id": "call_actual", "name": "read_terminal", "arguments": "{}", "status": "completed"]]])
            }
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            XCTAssertEqual(input.first(where: { $0["type"] as? String == "reasoning" })?["encrypted_content"] as? String, "opaque-openai")
            XCTAssertEqual(input.last?["call_id"] as? String, "call_actual")
            XCTAssertEqual(input.last?["output"] as? String, "fixture result")
            return (200, ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]]])
        }
        let messages = [APIMessage(role: "system", content: "System"), APIMessage(role: "user", content: "Check")]
        let first = try await client.complete(provider: .openAI, key: "openai-test", model: "gpt-6-astra", messages: messages, mode: .ask)
        XCTAssertEqual(first.tool_calls?.first?.id, "call_actual")
        XCTAssertFalse((first.content ?? "").contains("opaque-openai"))
        let second = try await client.complete(provider: .openAI, key: "openai-test", model: "gpt-6-astra", messages: messages + [first, APIMessage(role: "tool", content: "fixture result", tool_call_id: "call_actual")], mode: .ask)
        XCTAssertEqual(second.content, "Done.")
    }

    func testAnthropicToolResultsAreGroupedAndThinkingIsPreserved() async throws {
        var count = 0
        ProviderURLProtocol.handler = { request, body in
            count += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(body["system"] as? String, "System")
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 2) // Manual mode exposes only reads.
            XCTAssertNotNil(tools.first?["input_schema"])
            if count == 1 {
                return (200, ["stop_reason": "tool_use", "content": [
                    ["type": "thinking", "thinking": "private-thinking", "signature": "signed-content"],
                    ["type": "tool_use", "id": "toolu_1", "name": "read_terminal", "input": [:]],
                    ["type": "tool_use", "id": "toolu_2", "name": "get_session_state", "input": [:]]]])
            }
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 3)
            let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            XCTAssertEqual(assistant.first?["signature"] as? String, "signed-content")
            let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
            XCTAssertEqual(messages[2]["role"] as? String, "user")
            XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["toolu_1", "toolu_2"])
            return (200, ["stop_reason": "end_turn", "content": [["type": "text", "text": "Verified."]]])
        }
        let messages = [APIMessage(role: "system", content: "System"), APIMessage(role: "user", content: "Check")]
        let first = try await client.complete(provider: .anthropic, key: "anthropic-test", model: "claude-sonnet-5", messages: messages, mode: .manual)
        XCTAssertFalse((first.content ?? "").contains("private-thinking"))
        let results = [APIMessage(role: "tool", content: "output", tool_call_id: "toolu_1"), APIMessage(role: "tool", content: "local", tool_call_id: "toolu_2")]
        let final = try await client.complete(provider: .anthropic, key: "anthropic-test", model: "claude-sonnet-5", messages: messages + [first] + results, mode: .manual)
        XCTAssertEqual(final.content, "Verified.")
    }

    func testSwitchingProvidersRetainsVisibleHistoryButDropsNativeBlocks() async throws {
        let previous = APIMessage(role: "assistant", content: "Previous finding", tool_calls: [ToolCall(id: "call_old", function: .init(name: "read_terminal", arguments: "{}"))], nativeProvider: .openAI, nativeContent: [.object(["encrypted_content": .string("private")])])
        let switched = previous.withoutReasoning()
        XCTAssertNil(switched.nativeProvider)
        XCTAssertNil(switched.nativeContent)
        ProviderURLProtocol.handler = { _, body in
            let data = try JSONSerialization.data(withJSONObject: body)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("private"))
            XCTAssertTrue(text.contains("Previous finding"))
            XCTAssertTrue(text.contains("call_old"))
            return (200, ["stop_reason": "end_turn", "content": [["type": "text", "text": "OK"]]])
        }
        _ = try await client.complete(provider: .anthropic, key: "test", model: "claude-sonnet-5", messages: [APIMessage(role: "user", content: "Check"), switched, APIMessage(role: "tool", content: "Result", tool_call_id: "call_old"), APIMessage(role: "user", content: "Continue")], mode: .ask)
    }

    func testRouterRouteUsesOnlyRouterEndpointAndAuthentication() async throws {
        ProviderURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer router-test")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertEqual(body["model"] as? String, "qwen/qwen3-coder")
            return (200, ["choices": [["message": ["role": "assistant", "content": "OK"]]]])
        }
        _ = try await client.complete(provider: .openRouter, key: "router-test", model: "qwen/qwen3-coder", messages: [APIMessage(role: "user", content: "test")], mode: .ask)
    }

    func testIncompleteAndEmptyNativeResponsesCannotExecuteActions() async {
        for provider in [AIProvider.openAI, .anthropic] {
            for empty in [false, true] {
                ProviderURLProtocol.handler = { _, _ in
                    if provider == .openAI {
                        return (200, ["status": empty ? "completed" : "incomplete", "output": []])
                    }
                    return (200, ["stop_reason": empty ? "end_turn" : "max_tokens", "content": []])
                }
                do {
                    _ = try await client.complete(provider: provider, key: "test", model: provider.defaultModel, messages: [], mode: .autonomous)
                    XCTFail("Must reject incomplete or empty replies")
                } catch { XCTAssertTrue(error.localizedDescription.contains(empty ? "empty" : "No actions")) }
            }
        }
    }

    func testProviderErrorsNeverEchoServerSecrets() async {
        for provider in [AIProvider.openAI, .anthropic] {
            ProviderURLProtocol.handler = { _, _ in (401, ["error": ["message": "SECRET-do-not-display"]]) }
            do {
                _ = try await client.complete(provider: provider, key: "test", model: provider.defaultModel, messages: [], mode: .ask)
                XCTFail("Expected error")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(provider.name))
                XCTAssertTrue(error.localizedDescription.contains("key was rejected"))
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }
}
