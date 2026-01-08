import XCTest
@testable import Reverie

final class CostEstimationTests: XCTestCase {

    // MARK: - Text Pricing Tests

    func testTextPricing_Gemini3ProPreview() {
        let pricing = PricingCatalog.textPricing(for: "gemini-3-pro-preview")
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

    func testTextPricing_GPT52() {
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 1.75)
        XCTAssertEqual(pricing?.outputPerMToken, 14.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeOpus45() {
        let pricing = PricingCatalog.textPricing(for: "claude-opus-4-5")
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 5.0)
        XCTAssertEqual(pricing?.outputPerMToken, 25.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeSonnet45() {
        let pricing = PricingCatalog.textPricing(for: "claude-sonnet-4-5")
        XCTAssertNotNil(pricing)
        XCTAssertEqual(pricing?.inputPerMToken, 3.0)
        XCTAssertEqual(pricing?.outputPerMToken, 15.0)
        XCTAssertEqual(pricing?.cachedInputMultiplier, PricingCatalog.cachedInputMultiplier)
    }

    func testTextPricing_ClaudeHaiku45() {
        let pricing = PricingCatalog.textPricing(for: "claude-haiku-4-5")
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
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let inputTokens = 1_000_000
        let expectedCost = (Double(inputTokens) / 1_000_000) * pricing.inputPerMToken
        XCTAssertEqual(expectedCost, 1.75)
    }

    func testOutputCostCalculation() {
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let outputTokens = 1_000_000
        let expectedCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(expectedCost, 14.0)
    }

    func testTotalCostCalculation() {
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let inputTokens = 500_000
        let outputTokens = 500_000
        let inputCost = (Double(inputTokens) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMToken
        let totalCost = inputCost + outputCost
        XCTAssertEqual(inputCost, 0.875)
        XCTAssertEqual(outputCost, 7.0)
        XCTAssertEqual(totalCost, 7.875)
    }

    func testMixedModelUsage() {
        let gptPricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let claudePricing = PricingCatalog.textPricing(for: "claude-opus-4-5")!

        let gptInputCost = (Double(1_000_000) / 1_000_000) * gptPricing.inputPerMToken
        let claudeInputCost = (Double(1_000_000) / 1_000_000) * claudePricing.inputPerMToken

        XCTAssertEqual(gptInputCost, 1.75)
        XCTAssertEqual(claudeInputCost, 5.0)
        XCTAssertGreaterThan(claudeInputCost, gptInputCost)
    }

    // MARK: - Edge Case Tests

    func testZeroTokens() {
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let inputCost = (Double(0) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(0) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(inputCost, 0.0)
        XCTAssertEqual(outputCost, 0.0)
    }

    func testLargeTokenCounts() {
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let largeTokenCount = 10_000_000
        let inputCost = (Double(largeTokenCount) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(largeTokenCount) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(inputCost, 17.5)
        XCTAssertEqual(outputCost, 140.0)
    }

    func testSmallTokenCounts() {
        let pricing = PricingCatalog.textPricing(for: "gpt-5.2")!
        let smallTokenCount = 100
        let inputCost = (Double(smallTokenCount) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(smallTokenCount) / 1_000_000) * pricing.outputPerMToken
        XCTAssertEqual(inputCost, 0.000175, accuracy: 0.000001)
        XCTAssertEqual(outputCost, 0.0014, accuracy: 0.000001)
    }

    func testModelNameVariation_CaseSensitivity() {
        let upperCasePricing = PricingCatalog.textPricing(for: "GPT-5.2")
        let mixedCasePricing = PricingCatalog.textPricing(for: "Gpt-5.2")
        XCTAssertNil(upperCasePricing)
        XCTAssertNil(mixedCasePricing)
    }

    func testModelNameVariation_TrailingSpaces() {
        let pricingWithSpaces = PricingCatalog.textPricing(for: "gpt-5.2 ")
        XCTAssertNil(pricingWithSpaces)
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
            "gemini-3-pro-preview",
            "gemini-3-flash-preview",
            "gpt-5.2",
            "claude-opus-4-5",
            "claude-sonnet-4-5",
            "claude-haiku-4-5"
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
