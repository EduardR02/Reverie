import Foundation

@MainActor
final class LLMService {
    typealias StreamChunk = LLMStreamChunk
    private weak var appState: AppState?
    
    // Set to true to capture real API responses into Documents/Reader/Captures
    var recordMode: Bool = false

    private let session: URLSession

    init(appState: AppState? = nil, session: URLSession? = nil) {
        self.appState = appState
        
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600 // 10 minutes
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    func setAppState(_ appState: AppState) {
        self.appState = appState
    }

    struct TokenUsage: Codable {
        var input: Int = 0
        var output: Int = 0
        var cached: Int?
        var reasoning: Int?

        var total: Int { input + output }
    }

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
            reasoning: settings.insightReasoningLevel,
            nameHint: "chapter_analysis"
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
            reasoning: .off,
            nameHint: "explain_word"
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
            reasoning: .off,
            nameHint: "image_prompt"
        )
    }

    // MARK: - Search Query Distillation

    func distillSearchQuery(
        insightTitle: String,
        insightContent: String,
        bookTitle: String,
        author: String,
        settings: UserSettings
    ) async throws -> String {
        let prompt = PromptLibrary.distillSearchQueryPrompt(
            insightTitle: insightTitle,
            insightContent: insightContent,
            bookTitle: bookTitle,
            author: author
        )

        // Always use Flash (or cheapest) for this fast task
        let (provider, model, key) = classificationModelSelection(settings: settings)

        return try await requestText(
            prompt: prompt,
            provider: provider,
            model: model,
            apiKey: key,
            temperature: settings.temperature,
            reasoning: .off,
            nameHint: "distill_search"
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
            reasoning: settings.chatReasoningLevel,
            nameHint: "chat"
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
            reasoning: settings.chatReasoningLevel,
            nameHint: "chat_stream"
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
            reasoning: settings.insightReasoningLevel,
            nameHint: "more_insights"
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
            reasoning: settings.insightReasoningLevel,
            nameHint: "more_questions"
        )

        return analysis.quizQuestions
    }

    // MARK: - Chapter Classification

    func classifyChapters(
        chapters: [(index: Int, title: String, preview: String)],
        settings: UserSettings
    ) async throws -> [Int: Bool] {
        let prompt = PromptLibrary.chapterClassificationPrompt(chapters: chapters)
        let (provider, model, key) = classificationModelSelection(settings: settings)

        guard !key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw LLMError.noAPIKey(provider)
        }

        let response: ClassificationResponse = try await requestStructured(
            prompt: prompt,
            schema: SchemaLibrary.chapterClassification,
            provider: provider,
            model: model,
            apiKey: key,
            temperature: 0.3,
            reasoning: .off,
            nameHint: "chapter_classification"
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
    func classificationModelSelection(settings: UserSettings) -> (LLMProvider, String, String) {
        if settings.useCheapestModelForClassification {
            // 1. If Google Key exists -> ALWAYS prefer Gemini Flash
            let googleKey = settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !googleKey.isEmpty {
                return (.google, "gemini-3-flash-preview", googleKey)
            }
            
            // 2. Otherwise, use the cheapest model from the CURRENT provider
            let provider = settings.llmProvider
            let currentKey = apiKey(for: provider, settings: settings).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !currentKey.isEmpty {
                switch provider {
                case .google: return (.google, "gemini-3-flash-preview", currentKey)
                case .openai: return (.openai, "gpt-5.2", currentKey)
                case .anthropic: return (.anthropic, "claude-haiku-4-5", currentKey)
                }
            }
            
            // 3. Fallback to any other key in order of "cheapness"
            if !settings.anthropicAPIKey.isEmpty {
                return (.anthropic, "claude-haiku-4-5", settings.anthropicAPIKey)
            }
            if !settings.openAIAPIKey.isEmpty {
                return (.openai, "gpt-5.2", settings.openAIAPIKey)
            }
        }
        
        // If setting is OFF, use CURRENTLY SELECTED model
        let currentProvider = settings.llmProvider
        let currentKey = apiKey(for: currentProvider, settings: settings).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !currentKey.isEmpty {
            return (currentProvider, settings.llmModel, currentKey)
        }

        // Final fallback
        if !settings.googleAPIKey.isEmpty {
            return (.google, "gemini-3-flash-preview", settings.googleAPIKey)
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
        reasoning: ReasoningLevel,
        nameHint: String? = nil
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
        if recordMode { recordResponse(data, name: nameHint ?? "text_response") }
        
        let (text, usage) = try client.parseResponseText(from: data)
        if let usage { recordUsage(usage) }
        return text
    }

    private func requestStructured<T: Decodable>(
        prompt: LLMRequestPrompt,
        schema: LLMStructuredSchema,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel,
        nameHint: String? = nil
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
        if recordMode { recordResponse(data, name: nameHint ?? "structured_response") }
        
        let (text, usage) = try client.parseResponseText(from: data)
        if let usage { recordUsage(usage) }
        return try decodeStructured(T.self, from: text)
    }

    private func recordUsage(_ usage: TokenUsage) {
        guard let appState = self.appState else { return }
        Task { @MainActor in
            appState.addTokens(
                input: usage.input,
                reasoning: usage.reasoning ?? 0,
                output: usage.output
            )
        }
    }

    private func recordResponse(_ data: Data, name: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let captureDir = docs.appendingPathComponent("Reader/Captures", isDirectory: true)
        
        try? fm.createDirectory(at: captureDir, withIntermediateDirectories: true)
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileURL = captureDir.appendingPathComponent("\(name)_\(timestamp).json")
        try? data.write(to: fileURL)
        print("Captured API response to: \(fileURL.path)")
    }

    private func decodeStructured<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        var cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks if present
        if cleanText.hasPrefix("```") {
            let lines = cleanText.components(separatedBy: .newlines)
            if lines.count >= 2 {
                // Drop first line (```json) and last line (```)
                let middleLines = lines.dropFirst().dropLast()
                cleanText = middleLines.joined(separator: "\n")
            }
        }
        
        guard let data = cleanText.data(using: .utf8) else {
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
        let (data, response) = try await session.data(for: request)
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
        reasoning: ReasoningLevel,
        nameHint: String? = nil
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

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMError.invalidResponse
                    }

                    if httpResponse.statusCode != 200 {
                        throw LLMError.httpError(httpResponse.statusCode)
                    }

                    // A temporary continuation to intercept usage chunks
                    let interceptor = AsyncThrowingStream<StreamChunk, Error> { inner in
                        Task {
                            do {
                                var lineParser = SSELineParser()
                                for try await byte in bytes {
                                    try lineParser.append(byte: byte) { line in
                                        guard let payload = ssePayload(from: line) else { return }
                                        if payload == "[DONE]" { return }

                                        guard let data = payload.data(using: .utf8),
                                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                            return
                                        }

                                        try client.handleStreamEvent(json, continuation: inner)
                                    }
                                }
                                inner.finish()
                            } catch {
                                inner.finish(throwing: error)
                            }
                        }
                    }

                    for try await chunk in interceptor {
                        if case .usage(let usage) = chunk {
                            self.recordUsage(usage)
                        } else {
                            continuation.yield(chunk)
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
