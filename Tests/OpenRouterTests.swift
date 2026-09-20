import XCTest
@testable import BlackBoxCore

private final class RouterURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OpenRouterTests: XCTestCase {
    func testRecommendedRequestsOnlyRequireSupportedParameters() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RouterURLProtocol.handler = nil }
        for model in RecommendedModels.all {
            RouterURLProtocol.handler = { request in
                var data = request.httpBody
                if data == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var collected = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        collected.append(buffer, count: count)
                    }
                    data = collected
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
                XCTAssertNil(body["tool_choice"])
                XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], model.reasoningEffort)
                XCTAssertEqual(body["max_tokens"] as? Int, model.maxTokens)
                XCTAssertNil(body["parallel_tool_calls"], "Even false excludes Qwen providers when require_parameters is true")
                XCTAssertEqual((body["provider"] as? [String: Bool])?["require_parameters"], true)
                XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 5)
                XCTAssertEqual(body["model"] as? String, model.id)
                return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"Connected."}}]}"#.utf8))
            }
            let reply = try await OpenRouterClient(session: session).complete(key: "test-key", model: model.id, messages: [APIMessage(role: "user", content: "Connection test")], mode: .ask)
            XCTAssertEqual(reply.content, "Connected.")
        }
    }

    func testRoutingErrorsDistinguishPolicyAndParameterFailuresWithoutLeakingServerData() throws {
        func error(_ detail: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["error": ["message": detail, "metadata": ["raw": "SECRET-123"]]])
            return OpenRouterClient.responseError(status: 404, data: data).localizedDescription
        }
        XCTAssertTrue(try error("No endpoints found that support all requested parameters").contains("tools or parameters"))
        XCTAssertTrue(try error("No endpoints found matching your data policy").contains("data policy"))
        XCTAssertTrue(try error("No endpoints found").contains("routing settings"))
        XCTAssertFalse(try error("SECRET-123").contains("SECRET-123"))
        XCTAssertFalse(try error("No endpoints found SECRET-123").contains("SECRET-123"))
        XCTAssertTrue(OpenRouterClient.responseError(status: 401, data: Data()).localizedDescription.contains("key was rejected"))
        XCTAssertTrue(OpenRouterClient.responseError(status: 503, data: Data()).localizedDescription.contains("unavailable"))
    }
    func testSignedReasoningSurvivesRoundTripAndCanBeRemovedForModelSwitch() throws {
        let data = Data(#"{"role":"assistant","content":"Checking.","tool_calls":[{"id":"call_42","type":"function","function":{"name":"read_terminal","arguments":"{}"}}],"reasoning":"internal","reasoning_details":[{"type":"reasoning.encrypted","data":"opaque-signature","index":0,"nested":{"enabled":true,"empty":null}}]}"#.utf8)
        let message = try JSONDecoder().decode(APIMessage.self, from: data)
        let decoded = try JSONDecoder().decode(APIMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.reasoning_details, message.reasoning_details)
        let switched = decoded.withoutReasoning()
        XCTAssertNil(switched.reasoning)
        XCTAssertNil(switched.reasoning_details)
        XCTAssertEqual(switched.content, "Checking.")
        XCTAssertEqual(switched.tool_calls?.first?.id, "call_42")
    }

    func testTruncatedToolResponseIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RouterURLProtocol.handler = nil }
        RouterURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"send_text","arguments":"{}"}}]}}]}"#.utf8))
        }
        do {
            _ = try await OpenRouterClient(session: session).complete(key: "test", model: "openai/gpt-6-astra", messages: [], mode: .autonomous)
            XCTFail("Truncated tool calls must not reach execution")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No actions"))
        }
    }

}
