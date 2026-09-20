import Foundation

struct RecommendedModel: Identifiable {
    let id: String
    let name: String
    let role: String
    let maxTokens: Int
    let reasoningEffort: String?
}

enum RecommendedModels {
    static let defaultID = "qwen/qwen3-coder"
    static let all: [RecommendedModel] = [
        .init(id: defaultID, name: "Qwen3 Coder", role: "Everyday · Default", maxTokens: 4096, reasoningEffort: nil),
        .init(id: "anthropic/claude-sonnet-5", name: "Sonnet 5", role: "Everyday · Troubleshooting", maxTokens: 4096, reasoningEffort: "medium"),
        .init(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", role: "Economy · Quick checks", maxTokens: 4096, reasoningEffort: "low"),
        .init(id: "openai/gpt-6-astra", name: "GPT-6 Astra", role: "Deep analysis", maxTokens: 8192, reasoningEffort: "medium")
    ]
    static func find(_ id: String) -> RecommendedModel? { all.first { $0.id == id } }
    static func selectedModel(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: "openRouterModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultID : saved
    }
}

// Preserve provider reasoning blocks without interpreting or displaying their contents.
indirect enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Decimal.self) { self = .number(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}
