import XCTest
@testable import Reverie

final class ModelCatalogRegressionTests: XCTestCase {
    func testRequestedPublicModelIDsAreAvailableWithoutInventedAliases() throws {
        let requested: [(String, LLMProvider)] = [
            ("gpt-6.1-sol", .openai), ("gpt-6-astra", .openai), ("gpt-6-luna", .openai),
            ("claude-opus-5-5", .anthropic), ("claude-fable-5-1", .anthropic),
            ("claude-haiku-5-5", .anthropic),
            ("gemini-4-argon", .google), ("gemini-3.8-flash", .google)
        ]
        for (id, provider) in requested {
            let model = try XCTUnwrap(SupportedModels.model(for: id))
            XCTAssertEqual(model.id, id)
            XCTAssertEqual(model.provider, provider)
            XCTAssertTrue(model.capabilities.supportsStructuredOutput)
            XCTAssertTrue(model.capabilities.supportsWebSearch)
            XCTAssertTrue(provider.models.contains { $0.id == id })
            XCTAssertTrue(model.documentationURL.hasPrefix("https://"))
        }
        XCTAssertEqual(SupportedModels.model(for: "claude-fable-5-1")?.name, "Claude Fable 5.1")
        XCTAssertEqual(SupportedModels.model(for: "gemini-4-argon")?.requiresPaidTier, true)
        XCTAssertEqual(SupportedModels.capabilities(for: "gemini-4-argon")?.supportsTemperature, false)
        XCTAssertNil(SupportedModels.model(for: "gpt-6-guessed"))
        XCTAssertNil(SupportedModels.capabilities(for: "claude-opus-99"))
        XCTAssertNil(PricingCatalog.textPricing(for: "gemini-unknown"))
    }

    func testProviderSelectionsAndUtilityRolesAreConsistent() throws {
        let settings = UserSettings()
        XCTAssertTrue(settings.llmProvider.models.contains { $0.id == settings.llmModel })
        XCTAssertEqual(Set(SupportedModels.all.map(\.id)).count, SupportedModels.all.count)
        for provider in LLMProvider.allCases {
            XCTAssertEqual(provider.defaultModel.provider, provider)
            XCTAssertEqual(provider.models.filter(\.useForClassification).count, 1)
            let utility = try XCTUnwrap(SupportedModels.model(for: SupportedModels.utilityModel(for: provider)))
            XCTAssertEqual(utility.provider, provider)
            XCTAssertTrue(utility.useForClassification)
        }
        XCTAssertEqual(SupportedModels.utilityModel(for: .openai), "gpt-6-luna")
        XCTAssertEqual(SupportedModels.utilityModel(for: .google), "gemini-3.8-flash")
        XCTAssertEqual(SupportedModels.utilityModel(for: .anthropic), "claude-haiku-5-5")
        XCTAssertEqual(LLMProvider.openai.defaultModel.id, "gpt-6.1-sol")
    }
    func testOlderModelsAreNotOfferedButSavedSelectionsAndHistoricalCostsRemainUsable() throws {
        let historical: [(LLMProvider, String, Double)] = [
            (.google, SupportedModels.Google.gemini3FlashPreview, 0.0005),
            (.openai, SupportedModels.OpenAI.legacyGPT52, 0.00175),
            (.anthropic, SupportedModels.Anthropic.sonnet45, 0.003)
        ]
        for (provider, id, expectedCost) in historical {
            XCTAssertFalse(provider.models.contains { $0.id == id })
            var settings = UserSettings()
            settings.llmProvider = provider
            settings.llmModel = id
            XCTAssertEqual(settings.normalized().llmModel, id)
            let usage = LLMService.TokenUsage(input: 1_000, visibleOutput: 0)
            XCTAssertEqual(try XCTUnwrap(LLMCallUsage.calculatedCost(for: usage, model: id)), expectedCost, accuracy: 0.0000001)
        }
    }


    func testCallablePersistedSelectionsAreNotSilentlyUpgraded() {
        for model in SupportedModels.all {
            var settings = UserSettings()
            settings.llmProvider = model.provider
            settings.llmModel = model.id
            XCTAssertEqual(settings.normalized().llmModel, model.id)
            XCTAssertEqual(model.provider.modelName(for: model.id), model.name)
        }
        var retiredSettings = UserSettings()
        retiredSettings.llmModel = "gemini-3-pro-preview"
        XCTAssertEqual(retiredSettings.normalized().llmModel, "gemini-3.1-pro-preview")
        XCTAssertEqual(SupportedModels.canonicalLLMModelID("gpt-5.2"), "gpt-5.2")
    }

    func testModernReasoningNeverSendsUnsupportedOffOrMinimalEffort() throws {
        for id in ["gpt-6.1-sol", "gpt-6-astra"] {
            let capabilities = try XCTUnwrap(SupportedModels.capabilities(for: id))
            XCTAssertTrue(capabilities.thinkingAlwaysOn)
            XCTAssertFalse(capabilities.supportsTemperature)
            for level in ReasoningLevel.allCases {
                XCTAssertTrue(capabilities.reasoningEfforts.contains(level.openAIEffort(for: id)))
            }
            XCTAssertEqual(ReasoningLevel.off.openAIEffort(for: id), "low")
            XCTAssertEqual(ReasoningLevel.minimal.openAIEffort(for: id), "low")
        }
        for id in ["gemini-3.8-flash", "gemini-4-argon"] {
            let capabilities = try XCTUnwrap(SupportedModels.capabilities(for: id))
            for level in ReasoningLevel.allCases {
                XCTAssertTrue(capabilities.geminiThinkingLevels.contains(level.geminiLevel(for: id)))
            }
            XCTAssertEqual(ReasoningLevel.off.geminiLevel(for: id), "low")
            XCTAssertEqual(ReasoningLevel.minimal.geminiLevel(for: id), "low")
            XCTAssertEqual(ReasoningLevel.medium.geminiLevel(for: id), "medium")
        }
        XCTAssertEqual(ReasoningLevel.off.openAIEffort(for: "gpt-5.2"), "none")
        XCTAssertEqual(ReasoningLevel.off.geminiLevel(for: "gemini-3-flash-preview"), "minimal")
    }

    func testLunaSupportsCheapNonReasoningAndAllPublishedEfforts() throws {
        let model = try XCTUnwrap(SupportedModels.model(for: "gpt-6-luna"))
        XCTAssertEqual(model.capabilities.maxOutputTokens, 128_000)
        XCTAssertFalse(model.capabilities.thinkingAlwaysOn)
        XCTAssertTrue(model.capabilities.supportsExplicitPromptCaching)
        XCTAssertEqual(model.capabilities.reasoningEfforts, ["none", "low", "medium", "high", "xhigh", "max"])
        for level in ReasoningLevel.allCases {
            XCTAssertTrue(model.capabilities.reasoningEfforts.contains(level.openAIEffort(for: model.id)))
        }
        XCTAssertEqual(ReasoningLevel.off.openAIEffort(for: model.id), "none")
        XCTAssertEqual(ReasoningLevel.minimal.openAIEffort(for: model.id), "low")
    }

    func testClaudeAlwaysOnThinkingAndEffortAreModelSpecific() throws {
        for id in ["claude-opus-5-5", "claude-fable-5-1"] {
            let capabilities = try XCTUnwrap(SupportedModels.capabilities(for: id))
            XCTAssertEqual(capabilities.reasoning, .anthropicAdaptive)
            XCTAssertTrue(capabilities.thinkingAlwaysOn)
            XCTAssertFalse(capabilities.supportsForcedToolUse)
            XCTAssertFalse(capabilities.supportsTemperature)
            for level in ReasoningLevel.allCases {
                XCTAssertTrue(capabilities.reasoningEfforts.contains(level.anthropicEffort(for: id)))
            }
        }
        XCTAssertEqual(SupportedModels.capabilities(for: "claude-haiku-5-5")?.thinkingAlwaysOn, false)
        XCTAssertEqual(ReasoningLevel.xhigh.anthropicEffort(for: "claude-opus-5-5"), "xhigh")
        XCTAssertEqual(ReasoningLevel.xhigh.anthropicEffort(for: "claude-opus-4-6"), "max")
    }

    func testStandardTokenRatesUsePerModelCachePrices() throws {
        let sol = try XCTUnwrap(PricingCatalog.textPricing(for: "gpt-6.1-sol"))
        XCTAssertEqual(sol.inputPerMToken, 2)
        XCTAssertEqual(sol.outputPerMToken, 10)
        XCTAssertEqual(sol.inputPerMToken * sol.cachedInputMultiplier, 0.1, accuracy: 0.000001)
        XCTAssertEqual(sol.inputPerMToken * sol.cacheWriteInputMultiplier, 2.5)
        let luna = try XCTUnwrap(PricingCatalog.textPricing(for: "gpt-6-luna"))
        XCTAssertEqual(luna.inputPerMToken, 0.1)
        XCTAssertEqual(luna.outputPerMToken, 0.5)
        XCTAssertEqual(luna.inputPerMToken * luna.cachedInputMultiplier, 0.01, accuracy: 0.000001)
        XCTAssertEqual(luna.inputPerMToken * luna.cacheWriteInputMultiplier, 0.125, accuracy: 0.000001)
        let fable = try XCTUnwrap(PricingCatalog.textPricing(for: "claude-fable-5-1"))
        XCTAssertEqual(fable.inputPerMToken * fable.cachedInputMultiplier, 0.25)
        XCTAssertEqual(fable.inputPerMToken * fable.cacheWriteInputMultiplier, 12.5)
        let opus = try XCTUnwrap(PricingCatalog.textPricing(for: "claude-opus-5-5"))
        XCTAssertEqual(opus.inputPerMToken * opus.cachedInputMultiplier, 0.2, accuracy: 0.000001)
        XCTAssertEqual(PricingCatalog.textPricing(for: "gpt-5.2")?.inputPerMToken, 1.75)
    }

    func testLongPromptRatesApplyToWholeRequestAtExactThresholds() throws {
        let haikuBase = try XCTUnwrap(PricingCatalog.textPricing(for: "claude-haiku-5-5", inputTokens: 100_000))
        let haikuLong = try XCTUnwrap(PricingCatalog.textPricing(for: "claude-haiku-5-5", inputTokens: 100_001))
        XCTAssertEqual(haikuBase.inputPerMToken, 0.1)
        XCTAssertEqual(haikuBase.outputPerMToken, 0.5)
        XCTAssertEqual(haikuLong.inputPerMToken, 0.5)
        XCTAssertEqual(haikuLong.outputPerMToken, 2.5)
        for id in ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"] {
            let base = try XCTUnwrap(PricingCatalog.textPricing(for: id, inputTokens: 272_000))
            let long = try XCTUnwrap(PricingCatalog.textPricing(for: id, inputTokens: 272_001))
            XCTAssertEqual(long.inputPerMToken, base.inputPerMToken * 2)
            XCTAssertEqual(long.outputPerMToken, base.outputPerMToken * 1.5)
            XCTAssertEqual(long.cachedInputMultiplier, base.cachedInputMultiplier)
        }
    }

    func testPublishedGooglePriceChangesUseUTCDateBoundaries() throws {
        let formatter = ISO8601DateFormatter()
        let argonBefore = try XCTUnwrap(formatter.date(from: "2026-11-30T23:59:59Z"))
        let argonAfter = try XCTUnwrap(formatter.date(from: "2026-12-01T00:00:00Z"))
        XCTAssertEqual(PricingCatalog.textPricing(for: "gemini-4-argon", at: argonBefore)?.inputPerMToken, 2)
        XCTAssertEqual(PricingCatalog.textPricing(for: "gemini-4-argon", at: argonAfter)?.inputPerMToken, 4)
        XCTAssertEqual(PricingCatalog.textPricing(for: "gemini-4-argon", at: argonAfter)?.outputPerMToken, 20)
        let flashBefore = try XCTUnwrap(formatter.date(from: "2026-12-31T23:59:59Z"))
        let flashAfter = try XCTUnwrap(formatter.date(from: "2027-01-01T00:00:00Z"))
        XCTAssertEqual(PricingCatalog.textPricing(for: "gemini-3.8-flash", at: flashBefore)?.inputPerMToken, 0.75)
        XCTAssertEqual(PricingCatalog.textPricing(for: "gemini-3.8-flash", at: flashAfter)?.inputPerMToken, 1.5)
        XCTAssertEqual(PricingCatalog.textPricing(for: "gemini-3.8-flash", at: flashAfter)?.outputPerMToken, 7.5)
    }

    func testAccumulatingCostUsesLongPromptTierRatherThanBaseQuote() {
        var tracker = ProcessingCostTracker()
        tracker.updateProcessingCost(inputTokens: 100_001, outputTokens: 10_000, model: "claude-haiku-5-5")
        XCTAssertEqual(tracker.processingCostEstimate, 0.0750005, accuracy: 0.0000001)
    }

    func testLegacySettingsDecodeWithoutLosingPreferencesWhenAuthModeIsAbsent() throws {
        var original = UserSettings()
        original.llmProvider = .openai
        original.llmModel = "gpt-5.2"
        original.openAIAPIKey = "saved-api-key"
        original.fontSize = 21
        original.imagesEnabled = true
        original.chatReasoningLevel = .high
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "openAIAuthenticationMode")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: legacyData)
        XCTAssertEqual(decoded.openAIAuthenticationMode, .apiKey)
        XCTAssertEqual(decoded, original)
    }

    func testSubscriptionAuthenticationModePersistsWithoutChangingAPIKey() throws {
        var settings = UserSettings()
        settings.openAIAPIKey = "saved-but-not-selected"
        settings.openAIAuthenticationMode = .chatGPTSubscription
        let decoded = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.openAIAuthenticationMode, .chatGPTSubscription)
        XCTAssertEqual(decoded.openAIAPIKey, settings.openAIAPIKey)
        XCTAssertEqual(decoded.hasAuthentication(for: .openai), OpenAISubscriptionAuth.isConnected)
    }

    func testAuthenticationChecksRejectWhitespaceKeys() {
        var settings = UserSettings()
        settings.googleAPIKey = " \n "
        settings.anthropicAPIKey = "\t"
        settings.openAIAPIKey = " "
        XCTAssertFalse(settings.hasAuthentication(for: .google))
        XCTAssertFalse(settings.hasAuthentication(for: .anthropic))
        XCTAssertFalse(settings.hasAuthentication(for: .openai))
        settings.openAIAPIKey = "api-key"
        XCTAssertTrue(settings.hasAuthentication(for: .openai))
    }
}
