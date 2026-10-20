import XCTest
@testable import Reverie

final class ProcessingCostTrackerTests: XCTestCase {

    // MARK: - Cost Accumulation

    func testAccumulatesSingleCallCost() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 1_000_000,
            outputTokens: 0,
            model: SupportedModels.OpenAI.gpt54
        )
        // A prompt above 272k uses the $5/MTok long-context input rate for the whole request.
        XCTAssertEqual(tracker.processingCostEstimate, 5, accuracy: 0.000001)
    }

    func testAccumulatesMultipleCalls() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 500_000,
            outputTokens: 500_000,
            model: SupportedModels.OpenAI.gpt54
        )
        // Long-context request: 0.5M * $5 input + 0.5M * $22.50 output = $13.75.
        XCTAssertEqual(tracker.processingCostEstimate, 13.75, accuracy: 0.000001)

        tracker.updateProcessingCost(
            inputTokens: 200_000,
            outputTokens: 100_000,
            model: SupportedModels.OpenAI.gpt54
        )
        // Additional: Input: 0.2M * $2.50 = $0.50, Output: 0.1M * $15.00 = $1.50
        // This second request is below the threshold, adding $2.00 at base rates.
        XCTAssertEqual(tracker.processingCostEstimate, 15.75, accuracy: 0.000001)
    }

    func testAccumulatesAcrossDifferentModels() {
        var tracker = ProcessingCostTracker()

        tracker.updateProcessingCost(
            inputTokens: 1_000_000,
            outputTokens: 0,
            model: SupportedModels.Google.gemini3FlashPreview
        )
        // Input: 1M * $0.50/MTok = $0.50
        XCTAssertEqual(tracker.processingCostEstimate, 0.50, accuracy: 0.000001)

        tracker.updateProcessingCost(
            inputTokens: 0,
            outputTokens: 1_000_000,
            model: SupportedModels.Anthropic.sonnet45
        )
        // Output: 1M * $15.00/MTok = $15.00
        // Cumulative: $0.50 + $15.00 = $15.50
        XCTAssertEqual(tracker.processingCostEstimate, 15.50, accuracy: 0.000001)
    }

    // MARK: - Reasoning Tokens

    func testReasoningTokensBilledAsOutput() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 0,
            outputTokens: 100,
            reasoningTokens: 200,
            model: SupportedModels.Google.gemini3FlashPreview
        )
        // Total output: 100 + 200 = 300 tokens
        // Cost: (300 / 1_000_000) * $3.00 = $0.0009
        XCTAssertEqual(tracker.processingCostEstimate, 0.0009, accuracy: 0.000001)
    }

    // MARK: - Cache Read / Write Pricing

    func testCacheReadTokensUseDiscountedPricing() {
        var tracker = ProcessingCostTracker()

        // All tokens are cached — should use cachedInputMultiplier (0.1)
        tracker.updateProcessingCost(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cachedTokens: 1_000_000,
            model: SupportedModels.OpenAI.gpt54
        )
        // The prompt-length tier still applies to cached input: 1M * ($5 * 0.1) = $0.50.
        XCTAssertEqual(tracker.processingCostEstimate, 0.5, accuracy: 0.000001)
    }

    func testCacheWriteTokensUseCacheWriteMultiplierForAnthropic() {
        var tracker = ProcessingCostTracker()

        // All tokens are cache-writes on Claude Sonnet 4.5 (multiplier: 1.25)
        tracker.updateProcessingCost(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheWriteTokens: 1_000_000,
            model: SupportedModels.Anthropic.sonnet45
        )
        // 1M cache write tokens * ($3.00 * 1.25) = $3.75
        XCTAssertEqual(tracker.processingCostEstimate, 3.75, accuracy: 0.000001)
    }

    func testMixedCacheAndUncachedInput() {
        var tracker = ProcessingCostTracker()

        // 1000 input: 400 cached, 300 cache-write, 300 uncached
        tracker.updateProcessingCost(
            inputTokens: 1000,
            outputTokens: 80,
            reasoningTokens: 7,
            cachedTokens: 400,
            cacheWriteTokens: 300,
            model: SupportedModels.Anthropic.sonnet45
        )
        // Uncached: 300 tokens → (300/1M) * $3.00 = $0.00090
        // Cached: 400 tokens → (400/1M) * ($3.00 * 0.1) = $0.00012
        // Cache-write: 300 tokens → (300/1M) * ($3.00 * 1.25) = $0.001125
        // Input total: $0.00090 + $0.00012 + $0.001125 = $0.002145
        // Output: 80 + 7 = 87 tokens → (87/1M) * $15.00 = $0.001305
        // Total: $0.002145 + $0.001305 = $0.00345
        XCTAssertEqual(tracker.processingCostEstimate, 0.00345, accuracy: 0.000001)
    }

    // MARK: - Setter Compatibility / Reset

    func testDirectWriteViaSetter() {
        var tracker = ProcessingCostTracker()
        tracker.processingCostEstimate = 42.0
        XCTAssertEqual(tracker.processingCostEstimate, 42.0)
    }

    func testResetViaSetter() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 1_000_000,
            outputTokens: 0,
            model: SupportedModels.OpenAI.gpt54
        )
        XCTAssertGreaterThan(tracker.processingCostEstimate, 0)

        tracker.processingCostEstimate = 0
        XCTAssertEqual(tracker.processingCostEstimate, 0)
    }

    // MARK: - Unknown Model / No Pricing

    func testUnknownModelIsIgnored() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            model: "nonexistent-model-v42"
        )
        XCTAssertEqual(tracker.processingCostEstimate, 0)
    }

    func testZeroTokensWithKnownModelYieldsZeroCost() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 0,
            outputTokens: 0,
            model: SupportedModels.Google.gemini3FlashPreview
        )
        XCTAssertEqual(tracker.processingCostEstimate, 0)
    }

    // MARK: - Edge Cases

    func testPartialNegativeUncachedInputIsClamped() {
        var tracker = ProcessingCostTracker()
        // Input is 100 but 200 is cached — uncached portion is clamped to 0.
        tracker.updateProcessingCost(
            inputTokens: 100,
            outputTokens: 0,
            cachedTokens: 200,
            model: SupportedModels.Google.gemini3FlashPreview
        )
        // uncachedTokens = max(0, 100 - 200 - 0) = 0
        // cachedCost = (200 / 1_000_000) * ($0.50 * 0.1) = $0.00001
        XCTAssertEqual(tracker.processingCostEstimate, 0.00001, accuracy: 1e-9)
    }

    func testVerySmallTokenCounts() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 1,
            outputTokens: 1,
            model: SupportedModels.OpenAI.gpt54
        )
        // (1/1M) * $2.50 + (1/1M) * $15.00 = $0.0000025 + $0.000015 = $0.0000175
        XCTAssertEqual(tracker.processingCostEstimate, 0.0000175, accuracy: 1e-10)
    }

    func testVeryLargeTokenCounts() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(
            inputTokens: 10_000_000,
            outputTokens: 10_000_000,
            model: SupportedModels.OpenAI.gpt54
        )
        // Long-context rates apply to both sides: 10M * $5 input + 10M * $22.50 output = $275.
        XCTAssertEqual(tracker.processingCostEstimate, 275, accuracy: 0.000001)
    }
}
