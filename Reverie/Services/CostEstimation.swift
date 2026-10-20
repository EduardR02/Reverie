import Foundation

enum CostEstimates {
    static let tokensPerWord: Double = 1.3
    static let classificationPreviewWordLimit: Int = 200
    static let classificationOutputTokensPerChapter: Int = 20
    static let imagePromptTokensPerImage: Int = 200
    static let imageOutputTokensPerImage: Int = 1_200

    /// Model-specific output token ranges based on real chapter analysis data
    static func analysisOutputTokensPerChapterRange(for modelId: String) -> ClosedRange<Int> {
        switch SupportedModels.model(for: modelId)?.provider {
        case .google: return 2_000...4_000
        case .openai: return 4_000...6_000
        case .anthropic: return 5_000...7_000
        case nil: return 3_000...5_000
        }
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

struct ModelPriceChange: Sendable {
    let effectiveDate: Date
    let inputPerMToken: Double
    let outputPerMToken: Double
}

/// Standard synchronous text-token rates in USD; search/tool fees and cache storage are separate.
struct ModelPricing: Sendable {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cachedInputMultiplier: Double
    var cacheWriteInputMultiplier: Double = 1
    var inputTokenThreshold: Int? = nil
    var longContextInputMultiplier: Double = 1
    var longContextOutputMultiplier: Double = 1
    var scheduledChange: ModelPriceChange? = nil

    func rates(inputTokens: Int, at date: Date) -> ModelPricing {
        let change = scheduledChange.flatMap { date >= $0.effectiveDate ? $0 : nil }
        let longContext = inputTokenThreshold.map { inputTokens > $0 } ?? false
        return ModelPricing(
            inputPerMToken: (change?.inputPerMToken ?? inputPerMToken) * (longContext ? longContextInputMultiplier : 1),
            outputPerMToken: (change?.outputPerMToken ?? outputPerMToken) * (longContext ? longContextOutputMultiplier : 1),
            cachedInputMultiplier: cachedInputMultiplier,
            cacheWriteInputMultiplier: cacheWriteInputMultiplier
        )
    }
}

struct ImagePricing {
    let inputPerMToken: Double
    let outputPerMToken: Double?
    let outputPerImage: Double?
}

enum PricingCatalog {
    static let cachedInputMultiplier: Double = 0.1

    static func textPricing(for modelId: String, inputTokens: Int = 0, at date: Date = Date()) -> ModelPricing? {
        SupportedModels.model(for: modelId)?.pricing.rates(inputTokens: inputTokens, at: date)
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
