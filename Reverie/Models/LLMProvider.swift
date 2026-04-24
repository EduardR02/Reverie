import Foundation

// MARK: - LLM Provider

enum LLMProvider: String, Codable, CaseIterable, CustomStringConvertible {
    case google = "Google"
    case openai = "OpenAI"
    case anthropic = "Anthropic"

    var description: String { displayName }

    var displayName: String {
        switch self {
        case .google: return "Gemini"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        }
    }

    func modelName(for id: String) -> String {
        let resolvedID = SupportedModels.canonicalLLMModelID(id)
        return models.first { $0.id == resolvedID }?.name ?? resolvedID
    }

    var models: [LLMModel] {
        switch self {
        case .google:
            return [
                LLMModel(id: SupportedModels.Google.gemini3FlashPreview, name: "Gemini 3 Flash"),
                LLMModel(id: SupportedModels.Google.gemini31ProPreview, name: "Gemini 3.1 Pro")
            ]
        case .openai:
            return [
                LLMModel(id: SupportedModels.OpenAI.gpt54, name: "GPT 5.4")
            ]
        case .anthropic:
            return [
                LLMModel(id: SupportedModels.Anthropic.opus46, name: "Claude 4.6 Opus"),
                LLMModel(id: SupportedModels.Anthropic.opus45, name: "Claude 4.5 Opus"),
                LLMModel(id: SupportedModels.Anthropic.sonnet45, name: "Claude 4.5 Sonnet"),
                LLMModel(id: SupportedModels.Anthropic.haiku45, name: "Claude 4.5 Haiku")
            ]
        }
    }
}
