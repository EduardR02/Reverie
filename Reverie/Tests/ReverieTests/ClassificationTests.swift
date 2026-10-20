import XCTest
@testable import Reverie

final class ClassificationTests: XCTestCase {
    var llmService: LLMService!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        llmService = LLMService()
    }

    @MainActor
    func testClassificationModelSelection() {
        var settings = UserSettings()
        settings.useCheapestModelForClassification = true
        
        // 1. Google Key exists -> Should use Gemini Flash regardless of primary provider
        settings.googleAPIKey = "g-key"
        settings.anthropicAPIKey = "a-key"
        settings.llmProvider = .anthropic
        settings.llmModel = "claude-sonnet-4-5"
        
        var (provider, model, key) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .google)
        XCTAssertEqual(model, SupportedModels.utilityModel(for: .google))
        XCTAssertEqual(key, "g-key")
        
        // 2. No Google Key, Anthropic Key exists, Anthropic selected -> Should use Haiku (cheapest)
        settings.googleAPIKey = ""
        settings.anthropicAPIKey = "a-key"
        settings.llmProvider = .anthropic
        settings.llmModel = "claude-sonnet-4-5"
        
        (provider, model, key) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .anthropic)
        XCTAssertEqual(model, SupportedModels.utilityModel(for: .anthropic))
        XCTAssertEqual(key, "a-key")
        
        // A provider's utility model is independent of the saved analysis-model selection.
        settings.googleAPIKey = ""
        settings.anthropicAPIKey = ""
        settings.openAIAPIKey = "o-key"
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.legacyGPT52
        
        (provider, model, key) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .openai)
        XCTAssertEqual(model, SupportedModels.utilityModel(for: .openai))
        
        // 4. Setting OFF -> Should always use currently selected model
        settings.useCheapestModelForClassification = false
        settings.googleAPIKey = "g-key"
        settings.anthropicAPIKey = "a-key"
        settings.llmProvider = .anthropic
        settings.llmModel = "claude-sonnet-4-5"
        
        (provider, model, key) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .anthropic)
        XCTAssertEqual(model, "claude-sonnet-4-5")
        XCTAssertEqual(key, "a-key")
    }

    @MainActor
    func testLunaUtilitySelectionPreservesInsightModelAndAuthenticationMode() {
        for mode in [OpenAIAuthenticationMode.apiKey, .chatGPTSubscription] {
            var settings = UserSettings()
            settings.llmProvider = .openai
            settings.llmModel = SupportedModels.OpenAI.gpt61Sol
            settings.openAIAuthenticationMode = mode
            settings.openAIAPIKey = "utility-fixture-key"
            settings.useCheapestModelForClassification = true
            let selection = llmService.classificationModelSelection(settings: settings)
            XCTAssertEqual(selection.0, .openai)
            XCTAssertEqual(selection.1, "gpt-6-luna")
            XCTAssertEqual(selection.2, mode == .apiKey ? "utility-fixture-key" : "")
            XCTAssertEqual(settings.llmModel, SupportedModels.OpenAI.gpt61Sol)
            XCTAssertEqual(settings.openAIAuthenticationMode, mode)

            settings.useCheapestModelForClassification = false
            let selected = llmService.classificationModelSelection(settings: settings)
            XCTAssertEqual(selected.1, SupportedModels.OpenAI.gpt61Sol)
            XCTAssertEqual(settings.openAIAuthenticationMode, mode)
        }
    }

    @MainActor
    func testDynamicKeyRemovalFallback() {
        var settings = UserSettings()
        settings.useCheapestModelForClassification = true
        
        // 1. Google Key exists -> Gemini
        settings.googleAPIKey = "g-key"
        settings.anthropicAPIKey = "a-key"
        var (provider, _, _) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .google)
        
        // 2. Remove Google Key -> Fallback to Anthropic (Haiku)
        settings.googleAPIKey = ""
        (provider, _, _) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .anthropic)
        
        // Removing every credential keeps the selected provider so its missing-auth error is accurate.
        settings.anthropicAPIKey = ""
        settings.openAIAPIKey = ""
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.legacyGPT52
        let missingAuthentication = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(missingAuthentication.0, settings.llmProvider)
        XCTAssertEqual(missingAuthentication.1, SupportedModels.utilityModel(for: settings.llmProvider))
        XCTAssertTrue(missingAuthentication.2.isEmpty)
        XCTAssertFalse(settings.hasAuthentication(for: missingAuthentication.0))
    }
}
