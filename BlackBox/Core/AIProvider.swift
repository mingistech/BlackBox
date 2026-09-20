import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case openRouter, openAI, anthropic
    var id: String { rawValue }
    var name: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }
    var keychainService: String { "BlackBox.\(name)" }
    var modelCatalogCacheKey: String { self == .openRouter ? "openRouterModelCatalog" : "\(rawValue)ModelCatalog" }
    var modelPreferenceKey: String { self == .openRouter ? "openRouterModel" : "\(rawValue)Model" }
    var defaultModel: String {
        switch self {
        case .openRouter: return RecommendedModels.defaultID
        case .openAI: return "gpt-6-astra"
        case .anthropic: return "claude-sonnet-5"
        }
    }
    var recommended: [RecommendedModel] {
        if self == .openRouter { return RecommendedModels.all }
        if self == .openAI {
            return [
                ("gpt-6-astra", "GPT-6 Astra"),
                ("gpt-5.6-sol", "GPT-5.6 Sol"),
                ("gpt-5.6-terra", "GPT-5.6 Terra"),
                ("gpt-5.6-luna", "GPT-5.6 Luna"),
                ("gpt-5.5", "GPT-5.5")
            ].map { id, name in
                RecommendedModel(id: id, name: name, role: id, maxTokens: 8192, reasoningEffort: nil)
            }
        }
        return [
            ("claude-sonnet-5", "Sonnet 5"),
            ("claude-fable-5-1", "Fable 5.1"),
            ("claude-opus-5", "Opus 5"),
            ("claude-haiku-4-5", "Haiku 4.5")
        ].map { id, name in
            RecommendedModel(id: id, name: name, role: id, maxTokens: 8192, reasoningEffort: nil)
        }
    }
    func selectedModel(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: modelPreferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultModel : saved
    }
    static func selected(defaults: UserDefaults = .standard) -> AIProvider {
        defaults.string(forKey: "aiProvider").flatMap(Self.init(rawValue:)) ?? .openRouter
    }
}
