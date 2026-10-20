import Foundation

enum ModelReasoning: Equatable, Sendable {
    case none
    case openAI
    case anthropicAdaptive
    case anthropicBudget
    case geminiLevel
    case geminiBudget
}

struct ModelCapabilities: Sendable {
    let reasoning: ModelReasoning
    let maxOutputTokens: Int
    var supportsTemperature: Bool = true
    var supportsWebSearch: Bool = true
    var supportsStructuredOutput: Bool = true
    var supportsForcedToolUse: Bool = true
    var supportsExplicitPromptCaching: Bool = false
    var thinkingAlwaysOn: Bool = false
    var reasoningEfforts: [String] = []
    var geminiThinkingLevels: [String] = []
}

struct LLMModel: Identifiable, Sendable {
    let id: String
    let name: String
    let provider: LLMProvider
    let capabilities: ModelCapabilities
    let pricing: ModelPricing
    let documentationURL: String
    var requiresPaidTier: Bool = false
    var useForClassification: Bool = false
    var isSelectable: Bool = true
}
