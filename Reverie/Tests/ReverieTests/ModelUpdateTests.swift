import XCTest
@testable import Reverie

final class ModelUpdateTests: XCTestCase {
    func testProviderModelListsExposeUpdatedModelIDs() {
        XCTAssertEqual(
            LLMProvider.google.models.map(\.id),
            [
                SupportedModels.Google.gemini3FlashPreview,
                SupportedModels.Google.gemini31ProPreview
            ]
        )

        XCTAssertEqual(
            LLMProvider.openai.models.map(\.id),
            [SupportedModels.OpenAI.gpt54]
        )

        XCTAssertEqual(
            LLMProvider.anthropic.models.map(\.id),
            [
                SupportedModels.Anthropic.opus46,
                SupportedModels.Anthropic.opus45,
                SupportedModels.Anthropic.sonnet45,
                SupportedModels.Anthropic.haiku45
            ]
        )
    }

    func testProviderModelDefaultIsStrongest() {
        // When switching provider, .models.first is used as default.
        // The first model in the list should be the strongest/best.
        // Anthropic default should be Opus 4.6
        XCTAssertEqual(
            LLMProvider.anthropic.models.first?.id,
            SupportedModels.Anthropic.opus46,
            "Anthropic default should be strongest (Opus 4.6)"
        )
        XCTAssertEqual(
            LLMProvider.anthropic.models.first?.name,
            "Claude 4.6 Opus"
        )

        // OpenAI has only one model, it's always the default
        XCTAssertEqual(
            LLMProvider.openai.models.first?.id,
            SupportedModels.OpenAI.gpt54
        )

        // Verify Anthropic ordering: strongest -> weakest
        XCTAssertGreaterThan(
            LLMProvider.anthropic.models.count,
            1,
            "Anthropic should have multiple models for ordering verification"
        )

        // Anthropic strong-to-weak: Opus 4.6 > Opus 4.5 > Sonnet 4.5 > Haiku 4.5
        let anthropicIDs = LLMProvider.anthropic.models.map(\.id)
        XCTAssertEqual(anthropicIDs, [
            SupportedModels.Anthropic.opus46,
            SupportedModels.Anthropic.opus45,
            SupportedModels.Anthropic.sonnet45,
            SupportedModels.Anthropic.haiku45
        ])
    }

    func testLegacyModelIDsNormalizeWithoutMutatingStoredSettings() throws {
        let defaults = UserDefaults.standard
        let key = "userSettings"
        let originalData = defaults.data(forKey: key)
        defer {
            if let originalData {
                defaults.set(originalData, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        var legacySettings = UserSettings()
        legacySettings.llmProvider = .google
        legacySettings.llmModel = SupportedModels.Google.legacyGemini3ProPreview
        defaults.set(try JSONEncoder().encode(legacySettings), forKey: key)

        XCTAssertEqual(UserSettings.load().llmModel, SupportedModels.Google.gemini31ProPreview)

        legacySettings.llmProvider = .openai
        legacySettings.llmModel = SupportedModels.OpenAI.legacyGPT52
        defaults.set(try JSONEncoder().encode(legacySettings), forKey: key)

        XCTAssertEqual(UserSettings.load().llmModel, SupportedModels.OpenAI.gpt54)

        let persistedData = try XCTUnwrap(defaults.data(forKey: key))
        let persistedSettings = try JSONDecoder().decode(UserSettings.self, from: persistedData)
        XCTAssertEqual(persistedSettings.llmModel, SupportedModels.OpenAI.legacyGPT52)
    }

    func testModelNamesResolveLegacyAliasesToCurrentNames() {
        XCTAssertEqual(LLMProvider.google.modelName(for: SupportedModels.Google.legacyGemini3ProPreview), "Gemini 3.1 Pro")
        XCTAssertEqual(LLMProvider.openai.modelName(for: SupportedModels.OpenAI.legacyGPT52), "GPT 5.4")
    }

    func testGemini31ProPreviewRequestUsesGemini3ThinkingConfig() throws {
        let provider = GeminiProvider()
        let request = try provider.makeRequest(
            prompt: LLMRequestPrompt(text: "Test prompt"),
            model: SupportedModels.Google.gemini31ProPreview,
            apiKey: "test-key",
            temperature: 0.7,
            reasoning: .high,
            schema: nil,
            stream: false,
            webSearch: true
        )

        XCTAssertTrue(request.url?.absoluteString.contains(SupportedModels.Google.gemini31ProPreview) == true)

        let body = try requestJSON(from: request)
        let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        let thinkingConfig = try XCTUnwrap(generationConfig["thinking_config"] as? [String: Any])
        XCTAssertNotNil(thinkingConfig["thinkingLevel"])
        XCTAssertNil(thinkingConfig["thinkingBudget"])
        XCTAssertEqual(thinkingConfig["include_thoughts"] as? Bool, true)
        XCTAssertNotNil(body["tools"] as? [[String: Any]])
    }

    func testOpenAIGPT54RequestUsesReasoningConfig() throws {
        let provider = OpenAIProvider()
        let request = try provider.makeRequest(
            prompt: LLMRequestPrompt(text: "Test prompt"),
            model: SupportedModels.OpenAI.gpt54,
            apiKey: "test-key",
            temperature: 0.9,
            reasoning: .medium,
            schema: nil,
            stream: false,
            webSearch: false
        )

        let body = try requestJSON(from: request)
        XCTAssertEqual(body["model"] as? String, SupportedModels.OpenAI.gpt54)
        XCTAssertNotNil(body["reasoning"] as? [String: Any])
        XCTAssertNil(body["temperature"])
    }

    func testAnthropicOpus46RequestSupportsThinking() throws {
        let provider = AnthropicProvider()
        let request = try provider.makeRequest(
            prompt: LLMRequestPrompt(text: "Test prompt"),
            model: SupportedModels.Anthropic.opus46,
            apiKey: "test-key",
            temperature: 0.4,
            reasoning: .high,
            schema: nil,
            stream: false,
            webSearch: false
        )

        let body = try requestJSON(from: request)
        XCTAssertEqual(body["model"] as? String, SupportedModels.Anthropic.opus46)
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
        XCTAssertNotNil(body["thinking"] as? [String: Any])
        XCTAssertNil(body["temperature"])
    }

    private func requestJSON(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
