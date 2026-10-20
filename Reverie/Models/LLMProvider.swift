import Foundation

// MARK: - LLM Provider

enum LLMProvider: String, Codable, CaseIterable, CustomStringConvertible, Sendable {
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
        if let model = SupportedModels.model(for: id), model.provider == self { return model.name }
        return id
    }

    var models: [LLMModel] {
        SupportedModels.models(for: self)
    }

    var defaultModel: LLMModel {
        models[0]
    }
}
