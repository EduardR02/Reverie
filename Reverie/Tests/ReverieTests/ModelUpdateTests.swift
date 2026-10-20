import XCTest
@testable import Reverie

final class ModelUpdateTests: XCTestCase {
    func testReasoningClampsToModelBoundsWithoutDroppingHighRequestsToLow() {
        XCTAssertEqual(ReasoningLevel.max.openAIEffort(for: SupportedModels.OpenAI.gpt61Sol), "max")
        XCTAssertEqual(ReasoningLevel.max.openAIEffort(for: SupportedModels.OpenAI.gpt54), "xhigh")
        XCTAssertEqual(ReasoningLevel.off.openAIEffort(for: SupportedModels.OpenAI.gpt61Sol), "low")
        XCTAssertEqual(ReasoningLevel.off.openAIEffort(for: SupportedModels.OpenAI.gpt6Luna), "none")
        XCTAssertEqual(ReasoningLevel.max.geminiLevel(for: SupportedModels.Google.gemini38Flash), "high")
        XCTAssertEqual(ReasoningLevel.off.geminiLevel(for: SupportedModels.Google.gemini38Flash), "low")
        XCTAssertEqual(ReasoningLevel.minimal.geminiLevel(for: SupportedModels.Google.gemini3FlashPreview), "minimal")
        XCTAssertEqual(ReasoningLevel.xhigh.anthropicEffort(for: SupportedModels.Anthropic.opus46), "max")
        XCTAssertEqual(ReasoningLevel.max.anthropicEffort(for: SupportedModels.Anthropic.opus46), "max")
    }

    func testIncreasingReasoningNeverReducesEffectiveEffort() {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        for model in SupportedModels.all {
            let effort: (ReasoningLevel) -> String
            switch model.capabilities.reasoning {
            case .openAI: effort = { $0.openAIEffort(for: model.id) }
            case .anthropicAdaptive: effort = { $0.anthropicEffort(for: model.id) }
            case .geminiLevel: effort = { $0.geminiLevel(for: model.id) }
            default: continue
            }
            let values = ReasoningLevel.allCases.map { order.firstIndex(of: effort($0))! }
            for (previous, next) in zip(values, values.dropFirst()) {
                XCTAssertLessThanOrEqual(previous, next, model.id)
            }
        }
    }

    func testMaxReasoningSettingsRoundTripWithoutChangingSelectedModel() throws {
        var settings = UserSettings()
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.gpt61Sol
        settings.insightReasoningLevel = .max
        settings.chatReasoningLevel = .max
        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.insightReasoningLevel, .max)
        XCTAssertEqual(restored.chatReasoningLevel, .max)
        XCTAssertEqual(restored.llmModel, settings.llmModel)
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
        let thinkingConfig = try XCTUnwrap(generationConfig["thinkingConfig"] as? [String: Any])
        XCTAssertNotNil(thinkingConfig["thinkingLevel"])
        XCTAssertNil(thinkingConfig["thinkingBudget"])
        XCTAssertEqual(thinkingConfig["includeThoughts"] as? Bool, true)
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
        XCTAssertEqual(body["max_tokens"] as? Int, 128_000)
        XCTAssertNotNil(body["thinking"] as? [String: Any])
        XCTAssertNil(body["temperature"])
    }

    private func requestJSON(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
