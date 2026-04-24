import Foundation

enum CostEstimates {
    static let tokensPerWord: Double = 1.3
    static let classificationPreviewWordLimit: Int = 200
    static let classificationOutputTokensPerChapter: Int = 20
    static let imagePromptTokensPerImage: Int = 200
    static let imageOutputTokensPerImage: Int = 1_200

    /// Model-specific output token ranges based on real chapter analysis data
    static func analysisOutputTokensPerChapterRange(for modelId: String) -> ClosedRange<Int> {
        if modelId.hasPrefix("gemini") {
            return 2_000...4_000
        } else if modelId.hasPrefix("gpt") {
            return 4_000...6_000
        } else if modelId.hasPrefix("claude") {
            return 5_000...7_000
        }
        return 3_000...5_000  // fallback
    }

    static func imagesPerChapter(for density: DensityLevel) -> Double {
        switch density {
        case .minimal: return 0.8
        case .low: return 2.0
        case .medium: return 4.0
        case .high: return 7.0
        case .xhigh: return 10.0
        }
    }
}

struct ModelPricing {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cachedInputMultiplier: Double

    /// Multiplier for tokens written to a prompt cache. Defaults to base input pricing.
    let cacheWriteInputMultiplier: Double

    init(inputPerMToken: Double, outputPerMToken: Double, cachedInputMultiplier: Double, cacheWriteInputMultiplier: Double = 1.0) {
        self.inputPerMToken = inputPerMToken
        self.outputPerMToken = outputPerMToken
        self.cachedInputMultiplier = cachedInputMultiplier
        self.cacheWriteInputMultiplier = cacheWriteInputMultiplier
    }
}

struct ImagePricing {
    let inputPerMToken: Double
    let outputPerMToken: Double?
    let outputPerImage: Double?
}

enum PricingCatalog {
    static let cachedInputMultiplier: Double = 0.1
    static let anthropicCacheWriteInputMultiplier: Double = 1.25

    static func textPricing(for modelId: String) -> ModelPricing? {
        switch SupportedModels.canonicalLLMModelID(modelId) {
        case SupportedModels.Google.gemini31ProPreview:
            return ModelPricing(inputPerMToken: 2, outputPerMToken: 12, cachedInputMultiplier: cachedInputMultiplier)
        case SupportedModels.Google.gemini3FlashPreview:
            return ModelPricing(inputPerMToken: 0.5, outputPerMToken: 3, cachedInputMultiplier: cachedInputMultiplier)
        case SupportedModels.OpenAI.gpt54:
            return ModelPricing(inputPerMToken: 2.5, outputPerMToken: 15, cachedInputMultiplier: cachedInputMultiplier)
        case SupportedModels.Anthropic.opus45, SupportedModels.Anthropic.opus46:
            return ModelPricing(inputPerMToken: 5, outputPerMToken: 25, cachedInputMultiplier: cachedInputMultiplier, cacheWriteInputMultiplier: anthropicCacheWriteInputMultiplier)
        case SupportedModels.Anthropic.sonnet45:
            return ModelPricing(inputPerMToken: 3, outputPerMToken: 15, cachedInputMultiplier: cachedInputMultiplier, cacheWriteInputMultiplier: anthropicCacheWriteInputMultiplier)
        case SupportedModels.Anthropic.haiku45:
            return ModelPricing(inputPerMToken: 1, outputPerMToken: 5, cachedInputMultiplier: cachedInputMultiplier, cacheWriteInputMultiplier: anthropicCacheWriteInputMultiplier)
        default:
            return nil
        }
    }

    static func imagePricing(for model: ImageModel) -> ImagePricing {
        switch model {
        case .gemini3Pro:
            return ImagePricing(inputPerMToken: 2, outputPerMToken: 12, outputPerImage: nil)
        case .gemini31Flash:
            return ImagePricing(inputPerMToken: 0.5, outputPerMToken: nil, outputPerImage: 0.10)
        case .gemini25Flash:
            return ImagePricing(inputPerMToken: 0.3, outputPerMToken: nil, outputPerImage: 0.039)
        }
    }
}
