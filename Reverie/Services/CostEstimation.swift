import Foundation

enum CostEstimates {
    static let tokensPerWord: Double = 1.3
    static let analysisOutputTokensPerChapterRange: ClosedRange<Int> = 2_000...4_000
    static let classificationPreviewWordLimit: Int = 200
    static let classificationOutputTokensPerChapter: Int = 20
    static let imagePromptTokensPerImage: Int = 200
    static let imageOutputTokensPerImage: Int = 1_200

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
}

struct ImagePricing {
    let inputPerMToken: Double
    let outputPerMToken: Double?
    let outputPerImage: Double?
}

enum PricingCatalog {
    static let cachedInputMultiplier: Double = 0.1

    static func textPricing(for modelId: String) -> ModelPricing? {
        switch modelId {
        case "gemini-3-pro-preview":
            return ModelPricing(inputPerMToken: 2, outputPerMToken: 12, cachedInputMultiplier: cachedInputMultiplier)
        case "gemini-3-flash-preview":
            return ModelPricing(inputPerMToken: 0.5, outputPerMToken: 3, cachedInputMultiplier: cachedInputMultiplier)
        case "gpt-5.2":
            return ModelPricing(inputPerMToken: 1.75, outputPerMToken: 14, cachedInputMultiplier: cachedInputMultiplier)
        case "claude-opus-4-5":
            return ModelPricing(inputPerMToken: 5, outputPerMToken: 25, cachedInputMultiplier: cachedInputMultiplier)
        case "claude-sonnet-4-5":
            return ModelPricing(inputPerMToken: 3, outputPerMToken: 15, cachedInputMultiplier: cachedInputMultiplier)
        case "claude-haiku-4-5":
            return ModelPricing(inputPerMToken: 1, outputPerMToken: 5, cachedInputMultiplier: cachedInputMultiplier)
        default:
            return nil
        }
    }

    static func imagePricing(for model: ImageModel) -> ImagePricing {
        switch model {
        case .gemini3Pro:
            return ImagePricing(inputPerMToken: 2, outputPerMToken: 12, outputPerImage: nil)
        case .gemini25Flash:
            return ImagePricing(inputPerMToken: 0.3, outputPerMToken: nil, outputPerImage: 0.039)
        }
    }
}
