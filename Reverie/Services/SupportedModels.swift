import Foundation

enum SupportedModels {
    enum Google {
        static let gemini38Flash = "gemini-3.8-flash"
        static let gemini4Argon = "gemini-4-argon"
        static let gemini3FlashPreview = "gemini-3-flash-preview"
        static let gemini31ProPreview = "gemini-3.1-pro-preview"
        static let legacyGemini3ProPreview = "gemini-3-pro-preview"
    }

    enum OpenAI {
        static let gpt61Sol = "gpt-6.1-sol"
        static let gpt6Astra = "gpt-6-astra"
        static let gpt6Luna = "gpt-6-luna"
        static let gpt54 = "gpt-5.4"
        static let legacyGPT52 = "gpt-5.2"
    }

    enum Anthropic {
        static let opus55 = "claude-opus-5-5"
        static let fable51 = "claude-fable-5-1"
        static let haiku55 = "claude-haiku-5-5"
        static let haiku45 = "claude-haiku-4-5"
        static let sonnet45 = "claude-sonnet-4-5"
        static let opus45 = "claude-opus-4-5"
        static let opus46 = "claude-opus-4-6"
    }

    // Official model pages verify IDs, access, reasoning limits and standard USD token rates.
    // Older metadata remains for saved requests and historical pricing, not picker choices.
    static let all: [LLMModel] = [
        LLMModel(
            id: Google.gemini38Flash, name: "Gemini 3.8 Flash", provider: .google,
            capabilities: ModelCapabilities(reasoning: .geminiLevel, maxOutputTokens: 65_536,
                thinkingAlwaysOn: true, geminiThinkingLevels: ["low", "medium", "high"]),
            pricing: ModelPricing(inputPerMToken: 0.75, outputPerMToken: 3.75, cachedInputMultiplier: 0.1,
                scheduledChange: ModelPriceChange(effectiveDate: Date(timeIntervalSince1970: 1_798_761_600), inputPerMToken: 1.5, outputPerMToken: 7.5)),
            documentationURL: "https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash",
            useForClassification: true
        ),
        LLMModel(
            id: Google.gemini4Argon, name: "Gemini 4 Argon", provider: .google,
            capabilities: ModelCapabilities(reasoning: .geminiLevel, maxOutputTokens: 65_536,
                supportsTemperature: false, thinkingAlwaysOn: true, geminiThinkingLevels: ["low", "medium", "high"]),
            pricing: ModelPricing(inputPerMToken: 2, outputPerMToken: 10, cachedInputMultiplier: 0.05,
                scheduledChange: ModelPriceChange(effectiveDate: Date(timeIntervalSince1970: 1_796_083_200), inputPerMToken: 4, outputPerMToken: 20)),
            documentationURL: "https://ai.google.dev/gemini-api/docs/models/gemini-4-argon",
            requiresPaidTier: true
        ),
        LLMModel(
            id: Google.gemini3FlashPreview, name: "Gemini 3 Flash", provider: .google,
            capabilities: ModelCapabilities(reasoning: .geminiLevel, maxOutputTokens: 65_536,
                geminiThinkingLevels: ["minimal", "low", "medium", "high"]),
            pricing: ModelPricing(inputPerMToken: 0.5, outputPerMToken: 3, cachedInputMultiplier: 0.1),
            documentationURL: "https://ai.google.dev/gemini-api/docs/models/gemini-3-flash-preview",
            isSelectable: false
        ),
        LLMModel(
            id: Google.gemini31ProPreview, name: "Gemini 3.1 Pro", provider: .google,
            capabilities: ModelCapabilities(reasoning: .geminiLevel, maxOutputTokens: 65_536,
                thinkingAlwaysOn: true, geminiThinkingLevels: ["low", "medium", "high"]),
            pricing: ModelPricing(inputPerMToken: 2, outputPerMToken: 12, cachedInputMultiplier: 0.1,
                inputTokenThreshold: 200_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
            documentationURL: "https://ai.google.dev/gemini-api/docs/models/gemini-3.1-pro-preview",
            isSelectable: false
        ),
        LLMModel(
            id: OpenAI.gpt61Sol, name: "GPT 6.1 Sol", provider: .openai,
            capabilities: ModelCapabilities(reasoning: .openAI, maxOutputTokens: 128_000,
                supportsTemperature: false, supportsExplicitPromptCaching: true, thinkingAlwaysOn: true,
                reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
            pricing: ModelPricing(inputPerMToken: 2, outputPerMToken: 10, cachedInputMultiplier: 0.05,
                cacheWriteInputMultiplier: 1.25, inputTokenThreshold: 272_000,
                longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-6.1-sol"
        ),
        LLMModel(
            id: OpenAI.gpt6Astra, name: "GPT 6 Astra", provider: .openai,
            capabilities: ModelCapabilities(reasoning: .openAI, maxOutputTokens: 128_000,
                supportsTemperature: false, supportsExplicitPromptCaching: true, thinkingAlwaysOn: true,
                reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
            pricing: ModelPricing(inputPerMToken: 10, outputPerMToken: 50, cachedInputMultiplier: 0.1,
                cacheWriteInputMultiplier: 1.25, inputTokenThreshold: 272_000,
                longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-6-astra"
        ),
        // 1,050,000 context / 922,000 maximum input tokens; subscription access is account/client dependent.
        // https://learn.chatgpt.com/docs/models
        LLMModel(
            id: OpenAI.gpt6Luna, name: "GPT 6 Luna", provider: .openai,
            capabilities: ModelCapabilities(reasoning: .openAI, maxOutputTokens: 128_000,
                supportsExplicitPromptCaching: true,
                reasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"]),
            pricing: ModelPricing(inputPerMToken: 0.1, outputPerMToken: 0.5, cachedInputMultiplier: 0.1,
                cacheWriteInputMultiplier: 1.25, inputTokenThreshold: 272_000,
                longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-6-luna",
            useForClassification: true
        ),
        LLMModel(
            id: OpenAI.gpt54, name: "GPT 5.4", provider: .openai,
            capabilities: ModelCapabilities(reasoning: .openAI, maxOutputTokens: 128_000,
                reasoningEfforts: ["none", "low", "medium", "high", "xhigh"]),
            pricing: ModelPricing(inputPerMToken: 2.5, outputPerMToken: 15, cachedInputMultiplier: 0.1,
                inputTokenThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.4",
            isSelectable: false
        ),
        LLMModel(
            id: OpenAI.legacyGPT52, name: "GPT 5.2", provider: .openai,
            capabilities: ModelCapabilities(reasoning: .openAI, maxOutputTokens: 128_000,
                reasoningEfforts: ["none", "low", "medium", "high", "xhigh"]),
            pricing: ModelPricing(inputPerMToken: 1.75, outputPerMToken: 14, cachedInputMultiplier: 0.1),
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.2",
            isSelectable: false
        ),
        LLMModel(
            id: Anthropic.opus55, name: "Claude Opus 5.5", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicAdaptive, maxOutputTokens: 128_000,
                supportsTemperature: false, supportsForcedToolUse: false, thinkingAlwaysOn: true,
                reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
            pricing: ModelPricing(inputPerMToken: 4, outputPerMToken: 20, cachedInputMultiplier: 0.05, cacheWriteInputMultiplier: 1.25),
            documentationURL: "https://platform.claude.com/docs/en/models/opus-5-5/overview"
        ),
        LLMModel(
            id: Anthropic.fable51, name: "Claude Fable 5.1", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicAdaptive, maxOutputTokens: 128_000,
                supportsTemperature: false, supportsForcedToolUse: false, thinkingAlwaysOn: true,
                reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
            pricing: ModelPricing(inputPerMToken: 10, outputPerMToken: 50, cachedInputMultiplier: 0.025, cacheWriteInputMultiplier: 1.25),
            documentationURL: "https://platform.claude.com/docs/en/models/fable-5-1/overview"
        ),
        LLMModel(
            id: Anthropic.haiku55, name: "Claude Haiku 5.5", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicAdaptive, maxOutputTokens: 128_000,
                supportsTemperature: false, reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
            pricing: ModelPricing(inputPerMToken: 0.1, outputPerMToken: 0.5, cachedInputMultiplier: 0.1,
                cacheWriteInputMultiplier: 1.25, inputTokenThreshold: 100_000,
                longContextInputMultiplier: 5, longContextOutputMultiplier: 5),
            documentationURL: "https://platform.claude.com/docs/en/models/haiku-5-5/overview",
            useForClassification: true
        ),
        LLMModel(
            id: Anthropic.opus46, name: "Claude 4.6 Opus", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicAdaptive, maxOutputTokens: 128_000,
                reasoningEfforts: ["low", "medium", "high", "max"]),
            pricing: ModelPricing(inputPerMToken: 5, outputPerMToken: 25, cachedInputMultiplier: 0.1, cacheWriteInputMultiplier: 1.25),
            documentationURL: "https://platform.claude.com/docs/en/about-claude/models/overview",
            isSelectable: false
        ),
        LLMModel(
            id: Anthropic.opus45, name: "Claude 4.5 Opus", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicBudget, maxOutputTokens: 64_000),
            pricing: ModelPricing(inputPerMToken: 5, outputPerMToken: 25, cachedInputMultiplier: 0.1, cacheWriteInputMultiplier: 1.25),
            documentationURL: "https://platform.claude.com/docs/en/about-claude/models/overview",
            isSelectable: false
        ),
        LLMModel(
            id: Anthropic.sonnet45, name: "Claude 4.5 Sonnet", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicBudget, maxOutputTokens: 64_000),
            pricing: ModelPricing(inputPerMToken: 3, outputPerMToken: 15, cachedInputMultiplier: 0.1, cacheWriteInputMultiplier: 1.25),
            documentationURL: "https://platform.claude.com/docs/en/about-claude/models/overview",
            isSelectable: false
        ),
        LLMModel(
            id: Anthropic.haiku45, name: "Claude 4.5 Haiku", provider: .anthropic,
            capabilities: ModelCapabilities(reasoning: .anthropicBudget, maxOutputTokens: 64_000),
            pricing: ModelPricing(inputPerMToken: 1, outputPerMToken: 5, cachedInputMultiplier: 0.1, cacheWriteInputMultiplier: 1.25),
            documentationURL: "https://platform.claude.com/docs/en/about-claude/models/overview",
            isSelectable: false
        )
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let byProvider = Dictionary(grouping: all.filter(\.isSelectable), by: \.provider)

    static func model(for id: String) -> LLMModel? {
        byID[canonicalLLMModelID(id)]
    }

    static func models(for provider: LLMProvider) -> [LLMModel] {
        byProvider[provider] ?? []
    }

    static func utilityModel(for provider: LLMProvider) -> String {
        models(for: provider).first(where: \.useForClassification)!.id
    }

    static func capabilities(for model: String) -> ModelCapabilities? {
        self.model(for: model)?.capabilities
    }

    static func canonicalLLMModelID(_ model: String) -> String {
        // This endpoint shut down March 9, 2026; other saved callable IDs are not upgrades.
        // https://ai.google.dev/gemini-api/docs/deprecations
        model == Google.legacyGemini3ProPreview ? Google.gemini31ProPreview : model
    }

    static func supportsGeminiImageSize(_ model: String) -> Bool {
        model.hasPrefix("gemini-3")
    }
}
