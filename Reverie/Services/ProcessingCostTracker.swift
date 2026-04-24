import Foundation

// MARK: - Processing Cost Tracking

/// Tracks cumulative API processing cost estimates using model-specific pricing.
/// Designed as a value type for clean observation integration via AppState.
struct ProcessingCostTracker {
    var processingCostEstimate: Double = 0

    /// Accumulates cost for a single API call.
    /// - Parameters:
    ///   - inputTokens: Total input tokens sent to the API.
    ///   - outputTokens: Visible output tokens returned.
    ///   - reasoningTokens: Reasoning/internal tokens (billed as output for Gemini).
    ///   - cachedTokens: Input tokens served from a context cache.
    ///   - cacheWriteTokens: Input tokens written to a context cache.
    ///   - model: Model identifier string (used to look up pricing via `PricingCatalog.textPricing(for:)`).
    /// - Note: If the model has no known pricing, the call is silently ignored.
    mutating func updateProcessingCost(
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        cachedTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        model: String
    ) {
        guard let pricing = PricingCatalog.textPricing(for: model) else { return }

        let uncachedTokens = max(0, inputTokens - cachedTokens - cacheWriteTokens)
        let uncachedCost = (Double(uncachedTokens) / 1_000_000) * pricing.inputPerMToken
        let cachedCost = (Double(cachedTokens) / 1_000_000) * (pricing.inputPerMToken * pricing.cachedInputMultiplier)
        let cacheWriteCost = (Double(cacheWriteTokens) / 1_000_000) * (pricing.inputPerMToken * pricing.cacheWriteInputMultiplier)

        let inputCost = uncachedCost + cachedCost + cacheWriteCost

        // Reasoning tokens are billed as output for Gemini
        let totalOutput = outputTokens + reasoningTokens
        let outputCost = (Double(totalOutput) / 1_000_000) * pricing.outputPerMToken

        processingCostEstimate += inputCost + outputCost
    }
}
