import Foundation

struct PromptHistory {
    private var prompts: [String] = []
    private var index: Int?
    private var savedDraft = ""

    mutating func record(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if prompts.last != prompt { prompts.append(prompt) }
        if prompts.count > 100 { prompts.removeFirst(prompts.count - 100) }
        index = nil
        savedDraft = ""
    }

    mutating func previous(draft: String) -> String? {
        guard !prompts.isEmpty else { return nil }
        if index == nil { savedDraft = draft }
        let next = max(0, (index ?? prompts.count) - 1)
        index = next
        return prompts[next]
    }

    mutating func next() -> String? {
        guard let current = index else { return nil }
        if current + 1 < prompts.count {
            index = current + 1
            return prompts[current + 1]
        }
        index = nil
        return savedDraft
    }
}
