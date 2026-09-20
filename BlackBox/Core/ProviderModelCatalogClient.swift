import Foundation

struct ProviderModelCatalogClient {
    var session: URLSession = .shared

    func fetch(provider: AIProvider, key: String? = nil) async throws -> [OpenRouterModel] {
        if provider != .openRouter, (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.message("Add your \(provider.name) API key in Settings to load available models.")
        }
        let endpoint: String
        switch provider {
        case .openRouter: endpoint = "https://openrouter.ai/api/v1/models"
        case .openAI: endpoint = "https://api.openai.com/v1/models"
        case .anthropic: endpoint = "https://api.anthropic.com/v1/models"
        }
        var models: [OpenRouterModel] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(string: endpoint)!
            if provider == .anthropic {
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
            }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 25
            if provider == .openAI { request.setValue("Bearer \(key!)", forHTTPHeaderField: "Authorization") }
            if provider == .anthropic {
                request.setValue(key!, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppError.message("Invalid model catalog response.") }
            guard (200..<300).contains(http.statusCode) else {
                if provider == .openRouter { throw OpenRouterClient.responseError(status: http.statusCode, data: data) }
                throw ModelClient.responseError(provider: provider, status: http.statusCode)
            }
            if provider == .openRouter {
                struct Response: Decodable { let data: [OpenRouterModel] }
                return try JSONDecoder().decode(Response.self, from: data).data
            }
            struct Entry: Decodable { let id: String; let display_name: String? }
            struct Page: Decodable { let data: [Entry]; let has_more: Bool?; let last_id: String? }
            let page = try JSONDecoder().decode(Page.self, from: data)
            models += page.data.map {
                OpenRouterModel(id: $0.id, name: $0.display_name ?? $0.id,
                                unavailableReason: provider == .openAI ? Self.unsupportedOpenAIReason($0.id) : nil)
            }
            if provider == .anthropic, page.has_more == true {
                guard let next = page.last_id, !next.isEmpty, seenCursors.insert(next).inserted, !page.data.isEmpty else {
                    throw AppError.message("The model catalog returned an invalid pagination cursor. Refresh to try again.")
                }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
    }

    // These dedicated API families cannot operate the text/function-call terminal assistant.
    // Keep them visible in the complete catalog, with their purpose explained.
    static func unsupportedOpenAIReason(_ id: String) -> String? {
        let id = id.lowercased()
        if id.contains("embedding") { return "Embedding model · No terminal tools" }
        if id.contains("moderation") { return "Moderation model · No terminal tools" }
        if id.hasPrefix("dall-e") || id.hasPrefix("gpt-image") || id.hasPrefix("chatgpt-image") { return "Image model · No terminal tools" }
        if id.hasPrefix("sora") { return "Video model · No terminal tools" }
        if id.contains("realtime") || id.hasPrefix("gpt-live") { return "Requires the Realtime API" }
        if id.contains("audio") || id.contains("transcribe") || id.contains("tts") || id.hasPrefix("whisper") { return "Audio model · No terminal tools" }
        if id.hasPrefix("babbage") || id.hasPrefix("davinci") || id.hasPrefix("text-") || id.hasPrefix("gpt-3.5-turbo-instruct") { return "Legacy completions model · No terminal tools" }
        return nil
    }
}
