import Foundation

final class LLMService {
    typealias StreamChunk = LLMStreamChunk

    struct ChapterAnalysis: Codable {
        var annotations: [AnnotationData] = []
        var quizQuestions: [QuizData] = []
        var imageSuggestions: [ImageSuggestion] = []
        var summary: String = ""

        init(
            annotations: [AnnotationData] = [],
            quizQuestions: [QuizData] = [],
            imageSuggestions: [ImageSuggestion] = [],
            summary: String = ""
        ) {
            self.annotations = annotations
            self.quizQuestions = quizQuestions
            self.imageSuggestions = imageSuggestions
            self.summary = summary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            annotations = try container.decodeIfPresent([AnnotationData].self, forKey: .annotations) ?? []
            quizQuestions = try container.decodeIfPresent([QuizData].self, forKey: .quizQuestions) ?? []
            imageSuggestions = try container.decodeIfPresent([ImageSuggestion].self, forKey: .imageSuggestions) ?? []
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        }
    }

    struct AnnotationData: Codable {
        let type: String
        let title: String
        let content: String
        let sourceBlockId: Int
    }

    struct QuizData: Codable {
        let question: String
        let answer: String
        let sourceBlockId: Int
    }

    struct ImageSuggestion: Codable {
        let excerpt: String
        let sourceBlockId: Int
    }

    struct ChapterClassification: Codable {
        let index: Int
        let type: String
    }

    private struct ClassificationResponse: Codable {
        let classifications: [ChapterClassification]
    }

    func explainWordChatPrompt(word: String, context: String) -> String {
        PromptLibrary.explainWordChatPrompt(word: word, context: context)
    }

    func imagePromptFromExcerpt(_ excerpt: String, rewrite: Bool = false) -> String {
        PromptLibrary.imagePromptFromExcerpt(excerpt, rewrite: rewrite)
    }

    // MARK: - Analyze Chapter

    func analyzeChapter(
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> ChapterAnalysis {
        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            insightDensity: settings.insightDensity,
            imageDensity: settings.imagesEnabled ? settings.imageDensity : nil
        )

        return try await requestStructured(
            prompt: prompt,
            schema: SchemaLibrary.chapterAnalysis,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel
        )
    }

    // MARK: - Word Explanation

    func explainWord(
        word: String,
        context: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> String {
        let prompt = PromptLibrary.explainWordPrompt(
            word: word,
            context: context,
            rollingSummary: rollingSummary
        )

        return try await requestText(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: .off
        )
    }

    // MARK: - Generate Image Prompt

    func generateImagePrompt(
        word: String,
        context: String,
        settings: UserSettings
    ) async throws -> String {
        let prompt = PromptLibrary.imagePrompt(word: word, context: context)

        return try await requestText(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: .off
        )
    }

    // MARK: - Chat (Q&A)

    func chat(
        message: String,
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> String {
        let prompt = PromptLibrary.chatPrompt(
            message: message,
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary
        )

        return try await requestText(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.chatReasoningLevel
        )
    }

    // MARK: - Streaming Chat

    func chatStreaming(
        message: String,
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let prompt = PromptLibrary.chatStreamingPrompt(
            message: message,
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary
        )

        return streamResponse(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.chatReasoningLevel
        )
    }

    // MARK: - Generate More Content

    func generateMoreInsights(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingTitles: [String],
        settings: UserSettings
    ) async throws -> [AnnotationData] {
        let prompt = PromptLibrary.moreInsightsPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            existingTitles: existingTitles,
            insightDensity: settings.insightDensity
        )

        let analysis: ChapterAnalysis = try await requestStructured(
            prompt: prompt,
            schema: SchemaLibrary.annotationsOnly,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel
        )

        return analysis.annotations
    }

    func generateMoreQuestions(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingQuestions: [String],
        settings: UserSettings
    ) async throws -> [QuizData] {
        let prompt = PromptLibrary.moreQuestionsPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            existingQuestions: existingQuestions
        )

        let analysis: ChapterAnalysis = try await requestStructured(
            prompt: prompt,
            schema: SchemaLibrary.quizOnly,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel
        )

        return analysis.quizQuestions
    }

    // MARK: - Chapter Classification

    /// Classifies all chapters in a book to identify garbage (front/back matter, empty, etc.)
    /// Uses Gemini 3 Flash if available, otherwise falls back to cheapest available model.
    /// Returns a dictionary mapping chapter index to isGarbage boolean.
    func classifyChapters(
        chapters: [(index: Int, title: String, preview: String)],
        settings: UserSettings
    ) async throws -> [Int: Bool] {
        let prompt = PromptLibrary.chapterClassificationPrompt(chapters: chapters)
        let (provider, model, key) = selectClassificationModel(settings: settings)

        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.noAPIKey(provider)
        }

        let response: ClassificationResponse = try await requestStructured(
            prompt: prompt,
            schema: SchemaLibrary.chapterClassification,
            provider: provider,
            model: model,
            apiKey: key,
            temperature: 0.3,
            reasoning: .off
        )

        var result: [Int: Bool] = [:]
        for classification in response.classifications {
            result[classification.index] = (classification.type == "garbage")
        }

        for i in 0..<chapters.count {
            if result[i] == nil {
                result[i] = false
            }
        }

        return result
    }

    /// Select the best model for classification (cheap and fast)
    private func selectClassificationModel(settings: UserSettings) -> (LLMProvider, String, String) {
        if !settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.google, "gemini-3-flash-preview", settings.googleAPIKey)
        }

        if !settings.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.anthropic, "claude-4.5-haiku", settings.anthropicAPIKey)
        }

        if !settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.openai, settings.llmModel, settings.openAIAPIKey)
        }

        return (.google, "gemini-3-flash-preview", "")
    }

    // MARK: - Request Handling

    private func requestText(
        prompt: LLMRequestPrompt,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMError.noAPIKey(provider)
        }

        let client = providerClient(for: provider)
        let request = try client.makeRequest(
            prompt: prompt,
            model: model,
            apiKey: trimmedKey,
            temperature: temperature,
            reasoning: reasoning,
            schema: nil,
            stream: false
        )

        let data = try await performRequest(request)
        return try client.parseResponseText(from: data)
    }

    private func requestStructured<T: Decodable>(
        prompt: LLMRequestPrompt,
        schema: LLMStructuredSchema,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel
    ) async throws -> T {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMError.noAPIKey(provider)
        }

        let client = providerClient(for: provider)
        let request = try client.makeRequest(
            prompt: prompt,
            model: model,
            apiKey: trimmedKey,
            temperature: temperature,
            reasoning: reasoning,
            schema: schema,
            stream: false
        )

        let data = try await performRequest(request)
        let text = try client.parseResponseText(from: data)
        return try decodeStructured(T.self, from: text)
    }

    private func decodeStructured<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw LLMError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func providerClient(for provider: LLMProvider) -> any LLMProviderClient {
        switch provider {
        case .google:
            return GeminiProvider()
        case .openai:
            return OpenAIProvider()
        case .anthropic:
            return AnthropicProvider()
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let message = parseErrorMessage(from: data) {
                throw LLMError.apiError(message)
            }
            throw LLMError.httpError(httpResponse.statusCode)
        }

        return data
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return nil
    }

    private func streamResponse(
        prompt: LLMRequestPrompt,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else {
                        continuation.finish(throwing: LLMError.noAPIKey(provider))
                        return
                    }

                    let client = providerClient(for: provider)
                    let request = try client.makeRequest(
                        prompt: prompt,
                        model: model,
                        apiKey: trimmedKey,
                        temperature: temperature,
                        reasoning: reasoning,
                        schema: nil,
                        stream: true
                    )

                    try await performStream(request, provider: client, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func performStream(
        _ request: URLRequest,
        provider: any LLMProviderClient,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        var lineParser = SSELineParser()

        func handleLine(_ line: String) throws {
            guard let payload = ssePayload(from: line) else { return }
            if payload == "[DONE]" { return }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            try provider.handleStreamEvent(json, continuation: continuation)
        }

        for try await byte in bytes {
            try lineParser.append(byte: byte, onLine: handleLine)
        }

        try lineParser.finalize(onLine: handleLine)
    }

    private func apiKey(for provider: LLMProvider, settings: UserSettings) -> String {
        switch provider {
        case .google: return settings.googleAPIKey
        case .openai: return settings.openAIAPIKey
        case .anthropic: return settings.anthropicAPIKey
        }
    }

    enum LLMError: LocalizedError {
        case invalidResponse
        case noAPIKey(LLMProvider)
        case apiError(String)
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from API"
            case .noAPIKey(let provider):
                return "Missing API key for \(provider.displayName). Add it in Settings."
            case .apiError(let message):
                return message
            case .httpError(let code):
                switch code {
                case 401, 403:
                    return "API key rejected. Check your key or provider."
                case 402:
                    return "Billing issue or insufficient funds."
                case 429:
                    return "Rate limit exceeded. Try again soon."
                default:
                    return "HTTP error: \(code)"
                }
            }
        }
    }
}
