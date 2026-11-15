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
        case .anthropic: return "claude-sonnet-5-5"
        }
    }
    var recommended: [RecommendedModel] {
        if self == .openRouter { return RecommendedModels.all }
        if self == .openAI {
            return [
                ("gpt-6-astra", "GPT-6 Astra"),
                ("gpt-6.1-sol", "GPT-6.1 Sol"),
                ("gpt-6.1-terra", "GPT-6.1 Terra"),
                ("gpt-6-luna", "GPT-6 Luna")
            ].map { id, name in
                RecommendedModel(id: id, name: name, role: id, maxTokens: 8192, reasoningEffort: "medium")
            }
        }
        return [
            ("claude-sonnet-5-5", "Sonnet 5.5"),
            ("claude-fable-5-2", "Fable 5.2"),
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-haiku-5-5", "Haiku 5.5")
        ].map { id, name in
            RecommendedModel(id: id, name: name, role: id, maxTokens: 8192, reasoningEffort: "medium")
        }
    }
    func supportedModel(_ id: String) -> String? {
        if self == .openRouter { return id }
        let replacements: [String: String] = self == .openAI
            ? ["gpt-5.6-sol": "gpt-6.1-sol", "gpt-5.6-terra": "gpt-6.1-terra", "gpt-5.6-luna": "gpt-6-luna"]
            : ["claude-sonnet-5": "claude-sonnet-5-5", "claude-fable-5-1": "claude-fable-5-2",
               "claude-opus-5": "claude-opus-5-5", "claude-haiku-4-5": "claude-haiku-5-5"]
        let candidate = replacements[id] ?? id
        return recommended.contains { $0.id == candidate } ? candidate : nil
    }
    func selectedModel(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: modelPreferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultModel : (supportedModel(saved) ?? defaultModel)
    }
    static func selected(defaults: UserDefaults = .standard) -> AIProvider {
        defaults.string(forKey: "aiProvider").flatMap(Self.init(rawValue:)) ?? .openRouter
    }
}
