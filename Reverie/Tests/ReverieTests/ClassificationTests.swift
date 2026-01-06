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
        XCTAssertEqual(model, "gemini-3-flash-preview")
        XCTAssertEqual(key, "g-key")
        
        // 2. No Google Key, Anthropic Key exists, Anthropic selected -> Should use Haiku (cheapest)
        settings.googleAPIKey = ""
        settings.anthropicAPIKey = "a-key"
        settings.llmProvider = .anthropic
        settings.llmModel = "claude-sonnet-4-5"
        
        (provider, model, key) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .anthropic)
        XCTAssertEqual(model, "claude-haiku-4-5")
        XCTAssertEqual(key, "a-key")
        
        // 3. No Google Key, No Anthropic Key, OpenAI selected -> Should use GPT 5.2
        settings.googleAPIKey = ""
        settings.anthropicAPIKey = ""
        settings.openAIAPIKey = "o-key"
        settings.llmProvider = .openai
        settings.llmModel = "gpt-5.2"
        
        (provider, model, key) = llmService.classificationModelSelection(settings: settings)
        XCTAssertEqual(provider, .openai)
        XCTAssertEqual(model, "gpt-5.2")
        
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
        
        // 3. Remove Anthropic Key -> Fallback to selected model (or Google if nothing else)
        settings.anthropicAPIKey = ""
        settings.openAIAPIKey = ""
        settings.llmProvider = .openai
        settings.llmModel = "gpt-5.2"
        (provider, _, _) = llmService.classificationModelSelection(settings: settings)
        // Since useCheapest is on, but no "cheap" keys exist, it uses the selected model (gpt-5.2) 
        // if it has no key, it might hit final fallback. 
        // In our logic: if current (openai) has no key, it hits final fallback (google).
        XCTAssertEqual(provider, .google)
    }
}
