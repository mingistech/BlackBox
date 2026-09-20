import Foundation

struct ToolCall: Codable, Identifiable {
    struct Function: Codable { var name: String; var arguments: String }
    var id: String
    var type: String = "function"
    var function: Function
}

struct APIMessage: Codable {
    var role: String
    var content: String?
    var tool_calls: [ToolCall]?
    var tool_call_id: String?
    var reasoning: String?
    var reasoning_details: [JSONValue]?
    var nativeProvider: AIProvider?
    var nativeContent: [JSONValue]?

    func withoutReasoning() -> APIMessage {
        var copy = self
        copy.reasoning = nil
        copy.reasoning_details = nil
        copy.nativeProvider = nil
        copy.nativeContent = nil
        return copy
    }
}

struct ToolArguments: Decodable {
    var text: String?
    var key: String?
    var wait_seconds: Double?
}

struct OpenRouterClient {
    var session: URLSession = .shared
    func complete(key: String, model: String, messages: [APIMessage], mode: AgentMode) async throws -> APIMessage {
        let encoded = try JSONEncoder().encode(messages)
        let recommendation = RecommendedModels.find(model)
        var body: [String: Any] = [
            "model": model,
            "messages": try JSONSerialization.jsonObject(with: encoded),
            "tools": Self.tools(mode: mode),
            "max_tokens": recommendation?.maxTokens ?? 4096,
            "stream": false
        ]
        // Auto tool choice is the default. Omit the optional parameter so providers
        // advertising tools without tool_choice remain available under require_parameters.
        if let effort = recommendation?.reasoningEffort { body["reasoning"] = ["effort": effort] }
        // Qwen providers support tools, but don't advertise parallel_tool_calls. With
        // require_parameters enabled, even false would filter those providers out.
        // AgentSession executes returned calls sequentially and applies approvals locally.
        body["provider"] = ["require_parameters": true]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("BlackBox", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppError.message("OpenRouter returned an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.responseError(status: response.statusCode, data: data)
        }
        struct Response: Decodable {
            struct Choice: Decodable { var message: APIMessage; var finish_reason: String? }
            var choices: [Choice]
        }
        let result: Response
        do { result = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw AppError.message("OpenRouter returned an unsupported response. Try another model.") }
        guard var message = result.choices.first?.message else { throw AppError.message("OpenRouter returned no response.") }
        if result.choices.first?.finish_reason == "length" {
            throw AppError.message("The model reached its output/reasoning limit before completing its response. No actions from that response were executed. Try a narrower request or another model.")
        }
        guard message.tool_calls?.count ?? 0 <= 8 else { throw AppError.message("Model requested too many simultaneous actions.") }
        message.role = "assistant"
        return message
    }

    static func responseError(status: Int, data: Data) -> AppError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = ((json?["error"] as? [String: Any])?["message"] as? String ?? "").lowercased()
        let explanation: String
        switch status {
        case 401: explanation = "The API key was rejected. Update it in Settings."
        case 402: explanation = "Your OpenRouter account needs credits."
        case 403: explanation = "Access was denied. Check your OpenRouter key permissions and account restrictions."
        case 404:
            if detail.contains("data policy") || detail.contains("data policies") || detail.contains("privacy") {
                explanation = "No provider matches your OpenRouter account's data policy. Review provider availability and your OpenRouter privacy settings, or choose another model."
            } else if detail.contains("parameter") || detail.contains("tool use") || detail.contains("tool calling") {
                explanation = "No available provider supports the requested tools or parameters. Try another tool-capable model or retry later."
            } else if detail.contains("no endpoints") {
                explanation = "No provider is available for this model with your account's routing settings. Check the model and provider availability, or try another model."
            } else {
                explanation = "The model or a compatible provider could not be found. Check the model ID in Settings and your OpenRouter provider settings."
            }
        case 429: explanation = "Rate limited. Wait a moment and try again."
        case 500...599: explanation = "OpenRouter or the model provider is unavailable. Retry shortly or choose another model."
        default: explanation = "OpenRouter rejected the request. Check the model ID and try again."
        }
        // Classify known server errors without echoing request data, credentials, or raw metadata.
        return .message("OpenRouter HTTP \(status). \(explanation)")
    }

    static func tools(mode: AgentMode) -> [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]]
        }
        let read = tool("read_terminal", "Read this window's terminal and new output. Optionally wait for output inactivity, up to 15 seconds. Inactivity does not prove command completion.", ["wait_seconds": ["type": "number", "minimum": 0, "maximum": 15]])
        let state = tool("get_session_state", "Read the current host, SSH, prompt, and running state of this window's terminal.")
        if mode == .manual { return [read, state] }
        return [read, state,
            tool("send_text", "Type text into the existing terminal. May contain a command and trailing newline to execute it in one approval. Never enter passwords, passphrases, or verification codes.", ["text": ["type": "string"]], required: ["text"]),
            tool("send_key", "Send one key to this terminal. Use return to execute previously typed text.", ["key": ["type": "string", "enum": ["return", "tab", "escape", "up", "down"]]], required: ["key"]),
            tool("interrupt_command", "Send Ctrl-C to the current foreground process. This does not close SSH.")
        ]
    }
}
