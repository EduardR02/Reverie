import Foundation

enum SupportedModels {
    enum Google {
        static let gemini3FlashPreview = "gemini-3-flash-preview"
        static let gemini31ProPreview = "gemini-3.1-pro-preview"
        static let legacyGemini3ProPreview = "gemini-3-pro-preview"
    }

    enum OpenAI {
        static let gpt54 = "gpt-5.4"
        static let legacyGPT52 = "gpt-5.2"
    }

    enum Anthropic {
        static let haiku45 = "claude-haiku-4-5"
        static let sonnet45 = "claude-sonnet-4-5"
        static let opus45 = "claude-opus-4-5"
        static let opus46 = "claude-opus-4-6"
    }

    static func canonicalLLMModelID(_ model: String) -> String {
        switch model {
        case Google.legacyGemini3ProPreview:
            return Google.gemini31ProPreview
        case OpenAI.legacyGPT52:
            return OpenAI.gpt54
        default:
            return model
        }
    }

    static func isGemini3Family(_ model: String) -> Bool {
        canonicalLLMModelID(model).hasPrefix("gemini-3")
    }

    static func isGemini25TextModel(_ model: String) -> Bool {
        model.contains("gemini-2.5") && !model.contains("image")
    }

    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        let resolvedModel = canonicalLLMModelID(model)
        return resolvedModel.hasPrefix("gpt-5") || resolvedModel.hasPrefix("o1") || resolvedModel.hasPrefix("o3")
    }

    static func supportsAnthropicThinking(_ model: String) -> Bool {
        model.contains("sonnet-4") || model.contains("opus-4") || model.contains("haiku-4") || model.contains("claude-4")
    }

    static func supportsGeminiImageSize(_ model: String) -> Bool {
        model.hasPrefix("gemini-3")
    }
}
