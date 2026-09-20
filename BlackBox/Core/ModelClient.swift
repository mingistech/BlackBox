import Foundation

/// Adapts each provider's wire format to the same locally enforced terminal tool loop.
struct ModelClient {
    var session: URLSession = .shared

    func complete(provider: AIProvider, key: String, model: String, messages: [APIMessage], mode: AgentMode) async throws -> APIMessage {
        let reply: APIMessage
        switch provider {
        case .openRouter:
            let routerMessages = messages.map { message in
                var copy = message
                copy.nativeProvider = nil
                copy.nativeContent = nil
                return copy
            }
            reply = try await OpenRouterClient(session: session).complete(key: key, model: model, messages: routerMessages, mode: mode)
        case .openAI:
            reply = try await openAI(key: key, model: model, messages: messages, mode: mode)
        case .anthropic:
            reply = try await anthropic(key: key, model: model, messages: messages, mode: mode)
        }
        let calls = reply.tool_calls ?? []
        guard calls.count <= 8, Set(calls.map(\.id)).count == calls.count,
              calls.allSatisfy({ !$0.id.isEmpty && !$0.function.name.isEmpty }) else {
            throw AppError.message("The model returned invalid or too many tool calls. No actions were executed.")
        }
        guard !calls.isEmpty || !(reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("\(provider.name) returned an empty response. Try again or choose another model.")
        }
        return reply
    }

    private func openAI(key: String, model: String, messages: [APIMessage], mode: AgentMode) async throws -> APIMessage {
        var input: [[String: Any]] = []
        for message in messages {
            if message.role == "assistant", message.nativeProvider == .openAI, let native = message.nativeContent {
                input += try objects(native)
            } else if message.role == "tool" {
                input.append(["type": "function_call_output", "call_id": message.tool_call_id ?? "", "output": message.content ?? ""])
            } else {
                if let content = message.content, !content.isEmpty {
                    input.append(["role": message.role, "content": content])
                }
                for call in message.tool_calls ?? [] {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.function.name, "arguments": call.function.arguments])
                }
            }
        }
        let tools = OpenRouterClient.tools(mode: mode).compactMap { tool -> [String: Any]? in
            guard var function = tool["function"] as? [String: Any] else { return nil }
            function["type"] = "function"
            function["strict"] = false // read_terminal's wait parameter remains optional.
            return function
        }
        var body: [String: Any] = ["model": model, "input": input, "tools": tools,
                                  "max_output_tokens": 8192, "parallel_tool_calls": false,
                                  "store": false, "include": ["reasoning.encrypted_content"]]
        if model == "gpt-6-astra" { body["reasoning"] = ["effort": "medium"] }
        let result = try await request(provider: .openAI, url: "https://api.openai.com/v1/responses", key: key, body: body)
        guard result["status"] as? String == "completed" else {
            throw AppError.message("OpenAI did not complete its response. No actions were executed. Try a narrower request or another model.")
        }
        guard let output = result["output"] as? [[String: Any]] else { throw invalid(.openAI) }
        var texts: [String] = []
        var calls: [ToolCall] = []
        for item in output {
            switch item["type"] as? String {
            case "message":
                for block in item["content"] as? [[String: Any]] ?? [] {
                    if let text = block["text"] as? String { texts.append(text) }
                    else if let refusal = block["refusal"] as? String { texts.append(refusal) }
                }
            case "function_call":
                guard let id = item["call_id"] as? String, let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String else { throw invalid(.openAI) }
                calls.append(ToolCall(id: id, function: .init(name: name, arguments: arguments)))
            case "reasoning": break
            default: throw invalid(.openAI)
            }
        }
        return APIMessage(role: "assistant", content: texts.joined(separator: "\n"), tool_calls: calls.isEmpty ? nil : calls,
                          nativeProvider: .openAI, nativeContent: try values(output))
    }

    private func anthropic(key: String, model: String, messages: [APIMessage], mode: AgentMode) async throws -> APIMessage {
        var system: [String] = []
        var converted: [[String: Any]] = []
        for message in messages {
            if message.role == "system" || message.role == "developer" {
                if let text = message.content { system.append(text) }
                continue
            }
            let role = message.role == "assistant" ? "assistant" : "user"
            var content: [[String: Any]] = []
            if message.role == "tool" {
                content = [["type": "tool_result", "tool_use_id": message.tool_call_id ?? "", "content": message.content ?? ""]]
            } else if message.role == "assistant", message.nativeProvider == .anthropic, let native = message.nativeContent {
                content = try objects(native)
            } else {
                if let text = message.content, !text.isEmpty { content.append(["type": "text", "text": text]) }
                for call in message.tool_calls ?? [] {
                    guard let arguments = try JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any] else {
                        throw invalid(.anthropic)
                    }
                    content.append(["type": "tool_use", "id": call.id, "name": call.function.name, "input": arguments])
                }
            }
            guard !content.isEmpty else { continue }
            // All parallel tool results must appear together in the next user message.
            if converted.last?["role"] as? String == role {
                let index = converted.count - 1
                converted[index]["content"] = (converted[index]["content"] as? [[String: Any]] ?? []) + content
            } else { converted.append(["role": role, "content": content]) }
        }
        let tools = OpenRouterClient.tools(mode: mode).compactMap { tool -> [String: Any]? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return ["name": function["name"] ?? "", "description": function["description"] ?? "", "input_schema": function["parameters"] ?? [:]]
        }
        var body: [String: Any] = ["model": model, "system": system.joined(separator: "\n\n"),
                                  "messages": converted, "tools": tools, "max_tokens": 8192]
        if model == "claude-sonnet-5" {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": "medium"]
        }
        let result = try await request(provider: .anthropic, url: "https://api.anthropic.com/v1/messages", key: key, body: body)
        guard let stop = result["stop_reason"] as? String, ["end_turn", "tool_use", "stop_sequence", "refusal"].contains(stop) else {
            throw AppError.message("Anthropic did not complete its response. No actions were executed. Try a narrower request or another model.")
        }
        guard let content = result["content"] as? [[String: Any]] else { throw invalid(.anthropic) }
        var texts: [String] = []
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text": if let text = block["text"] as? String { texts.append(text) }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                      let arguments = block["input"] as? [String: Any] else { throw invalid(.anthropic) }
                let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                calls.append(ToolCall(id: id, function: .init(name: name, arguments: String(decoding: encoded, as: UTF8.self))))
            case "thinking", "redacted_thinking": break
            default: throw invalid(.anthropic)
            }
        }
        return APIMessage(role: "assistant", content: texts.joined(separator: "\n"), tool_calls: calls.isEmpty ? nil : calls,
                          nativeProvider: .anthropic, nativeContent: try values(content))
    }

    private func request(provider: AIProvider, url: String, key: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw invalid(provider) }
        guard (200..<300).contains(http.statusCode) else { throw Self.responseError(provider: provider, status: http.statusCode) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw invalid(provider) }
        return json
    }

    static func responseError(provider: AIProvider, status: Int) -> AppError {
        let detail: String
        switch status {
        case 401: detail = "The API key was rejected. Update this provider's key in Settings."
        case 402: detail = "Check this provider's API billing and credits."
        case 403: detail = "Access was denied. Check this key's permissions and model access."
        case 404: detail = "The model was not found or is not available to this API account. Check the model ID in Settings."
        case 429: detail = "Rate or quota limit reached. Check API billing and limits, or retry later."
        case 500...599: detail = "The provider is temporarily unavailable. Retry shortly."
        default: detail = "The request was rejected. Check that the model supports tools and the selected API."
        }
        return .message("\(provider.name) HTTP \(status). \(detail)")
    }
    private func invalid(_ provider: AIProvider) -> AppError {
        .message("\(provider.name) returned an unsupported response. No actions were executed.")
    }
    private func values(_ objects: [[String: Any]]) throws -> [JSONValue] {
        try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: objects))
    }
    private func objects(_ values: [JSONValue]) throws -> [[String: Any]] {
        guard let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [[String: Any]] else {
            throw AppError.message("Invalid saved provider response.")
        }
        return objects
    }
}
