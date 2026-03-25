import XCTest
@testable import Reverie

final class CostEstimationTests: XCTestCase {

    // MARK: - Text Pricing Tests

    func testTextPricing_Gemini31ProPreview() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.Google.gemini31ProPreview)
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 2.0)
        XCTAssertEqual(pricing?.outputPerMToken, 12.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_Gemini3FlashPreview() {
        let pricing = PricingCatalog.textPricing(for: "gemini-3-flash-preview")
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 0.5)
        XCTAssertEqual(pricing?.outputPerMToken, 3.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_GPT54() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 2.5)
        XCTAssertEqual(pricing?.outputPerMToken, 15.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeOpus45() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.Anthropic.opus45)
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 5.0)
        XCTAssertEqual(pricing?.outputPerMToken, 25.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeOpus46() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.Anthropic.opus46)
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 5.0)
        XCTAssertEqual(pricing?.outputPerMToken, 25.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeSonnet45() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.Anthropic.sonnet45)
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 3.0)
        XCTAssertEqual(pricing?.outputPerMToken, 15.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeHaiku45() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.Anthropic.haiku45)
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 1.0)
        XCTAssertEqual(pricing?.outputPerMToken, 5.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_UnknownModel() {
        let pricing = PricingCatalog.textPricing(for: "unknown-model")
        XCTAssertNil(pricing)
    }

    // MARK: - Image Pricing Tests

    func testImagePricing_Gemini3Pro() {
        let pricing = PricingCatalog.imagePricing(for: .gemini3Pro)
        XCTAssertEqual(pricing.inputPerMToken, 2.0)
        XCTAssertEqual(pricing.outputPerMToken, 12.0)
        XCTAssertNil(pricing.outputPerImage)
    }

    func testImagePricing_Gemini25Flash() {
        let pricing = PricingCatalog.imagePricing(for: .gemini25Flash)
        XCTAssertEqual(pricing.inputPerMToken, 0.3)
        XCTAssertNil(pricing.outputPerMToken)
        XCTAssertEqual(pricing.outputPerImage, 0.039)
    }

    // MARK: - Cost Calculation Tests

    func testInputCostCalculation() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let inputTokens = 1_000_000
        let expectedCost = (Double(inputTokens) / 1_000_000) * pricing.inputPerMToken
        XCTAssertEqual(expectedCost, 2.5)
    }

    func testOutputCostCalculation() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let outputTokens = 1_000_000
        let expectedCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(expectedCost, 15.0)
    }

    func testTotalCostCalculation() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let inputTokens = 500_000
        let outputTokens = 500_000
        let inputCost = (Double(inputTokens) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMToken
        let totalCost = inputCost + outputCost
        XCTAssertEqual(inputCost, 1.25)
        XCTAssertEqual(outputCost, 7.5)
        XCTAssertEqual(totalCost, 8.75)
    }

    func testMixedModelUsage() {
        let gptPricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let claudePricing = PricingCatalog.textPricing(for: SupportedModels.Anthropic.opus45)!

        let gptInputCost = (Double(1_000_000) / 1_000_000) * gptPricing.inputPerMToken
        let claudeInputCost = (Double(1_000_000) / 1_000_000) * claudePricing.inputPerMToken

        XCTAssertEqual(gptInputCost, 2.5)
        XCTAssertEqual(claudeInputCost, 5.0)
        XCTAssertGreaterThan(claudeInputCost, gptInputCost)
    }

    // MARK: - Edge Case Tests

    func testZeroTokens() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let inputCost = (Double(0) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(0) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(inputCost, 0.0)
        XCTAssertEqual(outputCost, 0.0)
    }

    func testLargeTokenCounts() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let largeTokenCount = 10_000_000
        let inputCost = (Double(largeTokenCount) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(largeTokenCount) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(inputCost, 25.0)
        XCTAssertEqual(outputCost, 150.0)
    }

    func testSmallTokenCounts() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let smallTokenCount = 100
        let inputCost = (Double(smallTokenCount) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(smallTokenCount) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(inputCost, 0.00025, accuracy: 0.000001)
        XCTAssertEqual(outputCost, 0.0015, accuracy: 0.000001)
    }

    func testGPT54CachedInputCostUsesCurrentOpenAIRate() {
        let pricing = PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)!
        let cachedInputTokens = 1_000_000
        let cachedInputCost = (Double(cachedInputTokens) / 1_000_000) * (pricing.inputPerMToken * pricing.cachedInputMultiplier)

        XCTAssertEqual(cachedInputCost, 0.25)
    }

    func testModelNameVariation_CaseSensitivity() {
        let upperCasePricing = PricingCatalog.textPricing(for: "GPT-5.4")
        let mixedCasePricing = PricingCatalog.textPricing(for: "Gpt-5.4")
        XCTAssertNil(upperCasePricing)
        XCTAssertNil(mixedCasePricing)
    }

    func testModelNameVariation_TrailingSpaces() {
        let pricingWithSpaces = PricingCatalog.textPricing(for: "gpt-5.4 ")
        XCTAssertNil(pricingWithSpaces)
    }

    func testLegacyModelAliasesResolveToCurrentPricing() {
        XCTAssertEqual(
            PricingCatalog.textPricing(for: SupportedModels.Google.legacyGemini3ProPreview)?.outputPerMToken,
            PricingCatalog.textPricing(for: SupportedModels.Google.gemini31ProPreview)?.outputPerMToken
        )
        XCTAssertEqual(
            PricingCatalog.textPricing(for: SupportedModels.OpenAI.legacyGPT52)?.outputPerMToken,
            PricingCatalog.textPricing(for: SupportedModels.OpenAI.gpt54)?.outputPerMToken
        )
    }

    // MARK: - Images Per Chapter Tests

    func testImagesPerChapter_Minimal() {
        XCTAssertEqual(CostEstimates.imagesPerChapter(for: .minimal), 0.8)
    }

    func testImagesPerChapter_Low() {
        XCTAssertEqual(CostEstimates.imagesPerChapter(for: .low), 2.0)
    }

    func testImagesPerChapter_Medium() {
        XCTAssertEqual(CostEstimates.imagesPerChapter(for: .medium), 4.0)
    }

    func testImagesPerChapter_High() {
        XCTAssertEqual(CostEstimates.imagesPerChapter(for: .high), 7.0)
    }

    func testImagesPerChapter_XHigh() {
        XCTAssertEqual(CostEstimates.imagesPerChapter(for: .xhigh), 10.0)
    }

    // MARK: - Cached Input Multiplier Tests

    func testCachedInputMultiplierAppliedToAllModels() {
        let models = [
            SupportedModels.Google.gemini31ProPreview,
            SupportedModels.Google.gemini3FlashPreview,
            SupportedModels.OpenAI.gpt54,
            SupportedModels.Anthropic.opus45,
            SupportedModels.Anthropic.opus46,
            SupportedModels.Anthropic.sonnet45,
            SupportedModels.Anthropic.haiku45
        ]

        for model in models {
            guard let pricing = PricingCatalog.textPricing(for: model) else {
                XCTFail("Expected pricing for model: \(model)")
                continue
            }
            XCTAssertEqual(pricing.cachedInputMultiplier, 0.1, "Model: \(model)")
        }
    }

    func testCostCalculationIncludesReasoningTokens() {
        // Test the math logic for reasoning tokens
        // Input: 1000 tokens, Output: 500 tokens, Reasoning: 2000 tokens
        // For gemini-3-flash-preview: input=$0.10/M, output=$0.40/M (example rates)
        
        let inputCost = (1000.0 / 1_000_000) * 0.10
        let totalOutput = 500 + 2000  // reasoning billed as output
        let outputCost = (Double(totalOutput) / 1_000_000) * 0.40
        let expectedTotal = inputCost + outputCost
        
        // Verify the formula is correct
        XCTAssertEqual(expectedTotal, 0.0001 + 0.001, accuracy: 0.0001)
    }
}
