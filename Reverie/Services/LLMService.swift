import Foundation

@MainActor
final class LLMService {
    typealias StreamChunk = LLMStreamChunk
    private weak var appState: AppState?
    
    // Set to true to capture real API responses into Documents/Reverie/Captures
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
        /// Output tokens excluding reasoning (visible text only)
        var visibleOutput: Int = 0
        var cached: Int?
        var reasoning: Int?

        /// Total tokens including reasoning
        var total: Int { input + visibleOutput + (reasoning ?? 0) }
    }

    struct ChapterAnalysis: Codable {
        var annotations: [AnnotationData] = []
        var quizQuestions: [QuizData] = []
        var imageSuggestions: [ImageSuggestion] = []
        var summary: String = ""

        enum CodingKeys: String, CodingKey {
            case annotations, quizQuestions, imageSuggestions, summary
        }

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

    enum ChapterAnalysisStreamEvent {
        case thinking(String)
        case insightFound
        case quizQuestionFound
        case usage(TokenUsage)
        case completed(ChapterAnalysis)
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

    func analyzeChapterStreaming(
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        // Calculate word count for proportional guidance
        let wordCount = contentWithBlocks.split { $0.isWhitespace || $0.isNewline }.count

        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            insightDensity: settings.insightDensity,
            imageDensity: settings.imagesEnabled ? settings.imageDensity : nil,
            wordCount: wordCount
        )

        let stream = streamResponse(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel,
            schema: SchemaLibrary.chapterAnalysis(imagesEnabled: settings.imagesEnabled),
            webSearch: settings.webSearchEnabled,
            nameHint: "chapter_analysis_stream"
        )

        return streamChapterAnalysisEvents(
            from: stream,
            nameHint: "chapter_analysis_stream"
        )
    }

    internal func streamChapterAnalysisEvents(
        from stream: AsyncThrowingStream<LLMStreamChunk, Error>,
        nameHint: String? = nil
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var fullText = ""
                    var scanner = StreamingJSONScanner()

                    for try await chunk in stream {
                        switch chunk {
                        case .thinking(let text):
                            continuation.yield(.thinking(text))
                        case .usage(let usage):
                            continuation.yield(.usage(usage))
                        case .content(let text):
                            fullText += text
                            let (insights, quizzes) = scanner.update(with: text)
                            for _ in 0..<insights { continuation.yield(.insightFound) }
                            for _ in 0..<quizzes { continuation.yield(.quizQuestionFound) }
                        }
                    }

                    if recordMode, let data = fullText.data(using: .utf8), !fullText.isEmpty {
                        recordResponse(data, name: nameHint ?? "chapter_analysis_stream")
                    }

                    let finalAnalysis: ChapterAnalysis = try self.decodeStructured(ChapterAnalysis.self, from: fullText)
                    continuation.yield(.completed(finalAnalysis))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func analyzeChapter(
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> ChapterAnalysis {
        let stream = analyzeChapterStreaming(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            settings: settings
        )
        return try await collectChapterAnalysis(from: stream)
    }

    private func collectChapterAnalysis(
        from stream: AsyncThrowingStream<ChapterAnalysisStreamEvent, Error>
    ) async throws -> ChapterAnalysis {
        var finalAnalysis: ChapterAnalysis?

        for try await event in stream {
            if case .completed(let analysis) = event {
                finalAnalysis = analysis
            }
        }

        guard let finalAnalysis else {
            throw LLMError.invalidResponse
        }
        return finalAnalysis
    }

    // MARK: - Generate Summary (Fast Path)

    private struct SummaryResponse: Codable {
        let summary: String
    }

    /// Generates just the chapter summary using the cheapest available model.
    /// This enables pipelining: summary for chapter N+1 can start as soon as
    /// summary for chapter N completes, without waiting for insights.
    func generateSummary(
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> (summary: String, usage: TokenUsage?) {
        let prompt = PromptLibrary.summaryPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary
        )

        // Always use cheapest model for summary generation
        let (provider, model, key) = classificationModelSelection(settings: settings)

        let (response, usage): (SummaryResponse, TokenUsage?) = try await requestStructuredWithUsage(
            prompt: prompt,
            schema: SchemaLibrary.summaryOnly,
            provider: provider,
            model: model,
            apiKey: key,
            temperature: 0.3,
            reasoning: .off,
            nameHint: "chapter_summary"
        )

        return (response.summary, usage)
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
            webSearch: false, // Explicitly false
            nameHint: "distill_search"
        )
    }

    // MARK: - Chat (Streaming)

    func chatStreaming(
        message: String,
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let prompt = PromptLibrary.chatPrompt(
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
            webSearch: false, // Explicitly false
            nameHint: "chat_stream"
        )
    }

    // MARK: - Generate More Content

    func generateMoreInsightsStreaming(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingTitles: [String],
        settings: UserSettings
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        let prompt = PromptLibrary.moreInsightsPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            existingTitles: existingTitles,
            insightDensity: settings.insightDensity
        )

        let stream = streamResponse(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel,
            schema: SchemaLibrary.annotationsOnly,
            webSearch: settings.webSearchEnabled,
            nameHint: "more_insights_stream"
        )

        return streamChapterAnalysisEvents(
            from: stream,
            nameHint: "more_insights_stream"
        )
    }

    func generateMoreQuestionsStreaming(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingQuestions: [String],
        settings: UserSettings
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        let prompt = PromptLibrary.moreQuestionsPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            existingQuestions: existingQuestions
        )

        let stream = streamResponse(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel,
            schema: SchemaLibrary.quizOnly,
            webSearch: settings.webSearchEnabled, // Quiz generation also gets it
            nameHint: "more_questions_stream"
        )

        return streamChapterAnalysisEvents(
            from: stream,
            nameHint: "more_questions_stream"
        )
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
        webSearch: Bool = false,
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
            stream: false,
            webSearch: webSearch
        )

        let data = try await performRequest(request)
        if recordMode { recordResponse(data, name: nameHint ?? "text_response") }
        
        let (text, usage) = try client.parseResponseText(from: data)
        if let usage { recordUsage(usage, model: model) }
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
        webSearch: Bool = false,
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
            stream: false,
            webSearch: webSearch
        )

        let data = try await performRequest(request)
        if recordMode { recordResponse(data, name: nameHint ?? "structured_response") }
        
        let (text, usage) = try client.parseResponseText(from: data)
        if let usage { recordUsage(usage, model: model) }
        return try decodeStructured(T.self, from: text)
    }

    private func requestStructuredWithUsage<T: Decodable>(
        prompt: LLMRequestPrompt,
        schema: LLMStructuredSchema,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel,
        webSearch: Bool = false,
        nameHint: String? = nil
    ) async throws -> (T, TokenUsage?) {
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
            stream: false,
            webSearch: webSearch
        )

        let data = try await performRequest(request)
        if recordMode { recordResponse(data, name: nameHint ?? "structured_response") }

        let (text, usage) = try client.parseResponseText(from: data)
        if let usage { recordUsage(usage, model: model) }
        let result: T = try decodeStructured(T.self, from: text)
        return (result, usage)
    }

    private func recordUsage(_ usage: TokenUsage, model: String) {
        guard let appState = self.appState else { return }
        Task { @MainActor in
            appState.addTokens(
                input: usage.input,
                reasoning: usage.reasoning ?? 0,
                output: usage.visibleOutput,
                cached: usage.cached ?? 0
            )
            appState.updateProcessingCost(
                inputTokens: usage.input,
                outputTokens: usage.visibleOutput + (usage.reasoning ?? 0),  // Total billable output
                model: model
            )
        }
    }

    private func recordResponse(_ data: Data, name: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let captureDir = docs.appendingPathComponent("Reverie/Captures", isDirectory: true)

        try? fm.createDirectory(at: captureDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let fileURL = captureDir.appendingPathComponent("\(name)_\(timestamp).json")
        try? data.write(to: fileURL)
        print("Captured API response to: \(fileURL.path)")
    }

    /// Records streaming chunks to a JSONL file (one JSON object per line)
    private class StreamingRecorder {
        private var chunks: [Data] = []
        private let name: String
        private let timestamp: Int

        init(name: String) {
            self.name = name
            self.timestamp = Int(Date().timeIntervalSince1970)
        }

        func recordChunk(_ payload: String) {
            if let data = payload.data(using: .utf8) {
                chunks.append(data)
            }
        }

        func save() {
            guard !chunks.isEmpty else { return }
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let captureDir = docs.appendingPathComponent("Reverie/Captures", isDirectory: true)

            try? fm.createDirectory(at: captureDir, withIntermediateDirectories: true)

            let fileURL = captureDir.appendingPathComponent("\(name)_stream_\(timestamp).jsonl")
            let content = chunks.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Captured \(chunks.count) streaming chunks to: \(fileURL.path)")
        }
    }

    internal func decodeStructured<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Try decoding directly (most efficient)
        if let data = cleanText.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }

        // 2. Scan for any balanced JSON object to tolerate pre/post-amble.
        var depth = 0
        var startIndex: String.Index?
        var isInsideString = false
        var isEscaped = false
        var bestDecoded: T?
        var bestLength = 0

        for index in cleanText.indices {
            let char = cleanText[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" {
                    isEscaped = true
                    continue
                }
                if char == "\"" {
                    isInsideString = false
                }
                continue
            }

            if char == "\"" {
                isInsideString = true
                continue
            }

            if char == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
                continue
            }

            if char == "}" {
                if depth > 0 { depth -= 1 }
                if depth == 0, let start = startIndex {
                    let jsonContent = String(cleanText[start...index])
                    if let data = jsonContent.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(T.self, from: data) {
                        if jsonContent.count > bestLength {
                            bestLength = jsonContent.count
                            bestDecoded = decoded
                        }
                    }
                    startIndex = nil
                }
            }
        }

        if let decoded = bestDecoded {
            return decoded
        }

        throw LLMError.invalidResponse
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
        schema: LLMStructuredSchema? = nil,
        webSearch: Bool = false,
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
                        schema: schema,
                        stream: true,
                        webSearch: webSearch
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMError.invalidResponse
                    }

                    if httpResponse.statusCode != 200 {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        if let message = parseErrorMessage(from: errorData) {
                            throw LLMError.apiError(message)
                        }
                        throw LLMError.httpError(httpResponse.statusCode)
                    }

                    // A temporary continuation to intercept usage chunks
                    let streamRecorder = self.recordMode ? StreamingRecorder(name: nameHint ?? "stream") : nil
                    let interceptor = AsyncThrowingStream<StreamChunk, Error> { inner in
                        Task {
                            do {
                                var lineParser = SSELineParser()
                                var rawData = Data()
                                var sawPayload = false

                                func handleLine(_ line: String) throws {
                                    guard let payload = ssePayload(from: line) else { return }
                                    sawPayload = true
                                    if payload == "[DONE]" { return }

                                    // Record each streaming chunk for test fixture generation
                                    streamRecorder?.recordChunk(payload)

                                    guard let data = payload.data(using: .utf8),
                                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                        return
                                    }

                                    try client.handleStreamEvent(json, continuation: inner)
                                }

                                for try await byte in bytes {
                                    if !sawPayload {
                                        rawData.append(byte)
                                    }
                                    try lineParser.append(byte: byte, onLine: handleLine)
                                }
                                try lineParser.finalize(onLine: handleLine)

                                if !sawPayload {
                                    let (text, usage) = try client.parseResponseText(from: rawData)
                                    if let usage { inner.yield(.usage(usage)) }
                                    inner.yield(.content(text))
                                }
                                streamRecorder?.save()
                                inner.finish()
                            } catch {
                                streamRecorder?.save()
                                inner.finish(throwing: error)
                            }
                        }
                    }

                    for try await chunk in interceptor {
                        switch chunk {
                        case .usage(let usage):
                            self.recordUsage(usage, model: model)
                            continuation.yield(.usage(usage))
                        default:
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

// MARK: - Streaming JSON Scanner

/// A high-performance byte-based scanner that identifies specific JSON keys in a stream.
/// It uses a state-machine approach to avoid expensive string allocations and re-scanning.
internal struct StreamingJSONScanner {
    private enum MatchState {
        case searching
        case foundKey // Found "title" or "question"
    }

    private let insightKey = Array("\"title\"".utf8)
    private let quizKey = Array("\"question\"".utf8)
    
    // State tracking
    private var insightMatchIndex = 0
    private var quizMatchIndex = 0
    private var insightState: MatchState = .searching
    private var quizState: MatchState = .searching
    private var isInsideString = false
    private var isEscaped = false

    mutating func reset() {
        insightMatchIndex = 0
        quizMatchIndex = 0
        insightState = .searching
        quizState = .searching
        isInsideString = false
        isEscaped = false
    }

    /// Scans a NEW chunk of text for occurrences of insights and quizzes.
    mutating func update(with chunk: String) -> (Int, Int) {
        var insights = 0
        var quizzes = 0
        
        for byte in chunk.utf8 {
            if isEscaped { isEscaped = false }
            else if byte == 0x5C { isEscaped = true }
            else if byte == 0x22 { isInsideString.toggle() }
            
            // Insight Key Machine
            switch insightState {
            case .searching:
                if byte == insightKey[insightMatchIndex] {
                    insightMatchIndex += 1
                    if insightMatchIndex == insightKey.count {
                        insightState = .foundKey
                        insightMatchIndex = 0
                    }
                } else { insightMatchIndex = (byte == insightKey[0]) ? 1 : 0 }
            case .foundKey:
                if byte == 0x3A { insights += 1; insightState = .searching } // Colon :
                else if byte > 0x20 { insightState = .searching } // Non-whitespace breaks it
            }

            // Quiz Key Machine
            switch quizState {
            case .searching:
                if byte == quizKey[quizMatchIndex] {
                    quizMatchIndex += 1
                    if quizMatchIndex == quizKey.count {
                        quizState = .foundKey
                        quizMatchIndex = 0
                    }
                } else { quizMatchIndex = (byte == quizKey[0]) ? 1 : 0 }
            case .foundKey:
                if byte == 0x3A { quizzes += 1; quizState = .searching }
                else if byte > 0x20 { quizState = .searching }
            }
        }
        
        return (insights, quizzes)
    }
}
