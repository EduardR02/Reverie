import Foundation

@MainActor
final class LLMService {
    typealias StreamChunk = LLMStreamChunk
    private weak var appState: AppState?
    private let sessionID = UUID().uuidString

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    
    enum RequestKind {
        case summary
        case insight
        case chat
        case other

        var ledgerTask: String {
            switch self {
            case .summary: return "summary"
            case .insight: return "insight"
            case .chat: return "chat"
            case .other: return "other"
            }
        }
    }

    private actor ConcurrencyLimiter {
        private var inFlight: [LLMProvider: Int] = [:]
        private var queues: [LLMProvider: [CheckedContinuation<Void, Never>]] = [:]

        func acquire(provider: LLMProvider, limit: Int) async {
            let currentLimit = max(1, limit)
            let currentInFlight = inFlight[provider, default: 0]

            if currentInFlight < currentLimit {
                inFlight[provider] = currentInFlight + 1
                return
            }

            await withCheckedContinuation { continuation in
                queues[provider, default: []].append(continuation)
            }
        }

        func release(provider: LLMProvider) {
            if let queue = queues[provider], !queue.isEmpty {
                var newQueue = queue
                let next = newQueue.removeFirst()
                queues[provider] = newQueue
                next.resume()
            } else {
                inFlight[provider] = max(0, inFlight[provider, default: 0] - 1)
            }
        }
    }

    private let limiter = ConcurrencyLimiter()
    
    // Set to true to capture real API responses into Documents/Reverie/Captures
    var recordMode: Bool = false

    private let session: ResilientSession
    private let subscriptionAuth: OpenAISubscriptionAuth

    init(
        appState: AppState? = nil,
        session: URLSession? = nil,
        subscriptionAuth: OpenAISubscriptionAuth = .shared
    ) {
        self.appState = appState
        self.subscriptionAuth = subscriptionAuth
        
        if let session = session {
            self.session = ResilientSession(session: session)
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 1200
            config.timeoutIntervalForResource = 1200
            self.session = ResilientSession(configuration: config)
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
        var cacheWrite: Int?
        var reasoning: Int?

        /// Total tokens including reasoning
        var total: Int { input + visibleOutput + (reasoning ?? 0) }

        mutating func mergeStreamingUsage(_ next: TokenUsage) {
            if next.input > 0 { input = next.input }
            if next.visibleOutput > 0 { visibleOutput = max(visibleOutput, next.visibleOutput) }
            if let cached = next.cached { self.cached = max(self.cached ?? 0, cached) }
            if let cacheWrite = next.cacheWrite { self.cacheWrite = max(self.cacheWrite ?? 0, cacheWrite) }
            if let reasoning = next.reasoning { self.reasoning = max(self.reasoning ?? 0, reasoning) }
        }
    }

    struct ChatTurn: Equatable {
        enum Role: String {
            case user
            case assistant
        }

        let role: Role
        let content: String
        let providerState: LLMConversationState?

        init(role: Role, content: String, providerState: LLMConversationState? = nil) {
            self.role = role
            self.content = content
            self.providerState = providerState
        }
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
        let aspectRatio: String?

        init(excerpt: String, sourceBlockId: Int, aspectRatio: String? = nil) {
            self.excerpt = excerpt
            self.sourceBlockId = sourceBlockId
            self.aspectRatio = aspectRatio
        }
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

    func rewriteImagePrompt(originalPrompt: String, refusalReason: String, settings: UserSettings) async throws -> String {
        let prompt = PromptLibrary.rewriteImagePrompt(originalPrompt: originalPrompt, refusalReason: refusalReason)
        let rewritten = try await requestText(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: min(settings.temperature, 0.7),
            reasoning: .off,
            webSearch: false,
            nameHint: "image_prompt_rewrite",
            kind: .other,
            authenticationMode: settings.openAIAuthenticationMode
        )
        return rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Analyze Chapter

    func analyzeChapterStreaming(
        contentWithBlocks: String,
        rollingSummary: String?,
        bookTitle: String?,
        author: String?,
        settings: UserSettings,
        coveredIdeas: [String] = []
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        // Calculate word count for proportional guidance
        let wordCount = contentWithBlocks.split { $0.isWhitespace || $0.isNewline }.count

        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            bookTitle: bookTitle,
            author: author,
            insightDensity: settings.insightDensity,
            imageDensity: settings.imagesEnabled ? settings.imageDensity : nil,
            wordCount: wordCount,
            coveredIdeas: coveredIdeas
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
            nameHint: "chapter_analysis_stream",
            kind: .insight,
            authenticationMode: settings.openAIAuthenticationMode
        )

        return streamChapterAnalysisEvents(
            from: stream,
            nameHint: "chapter_analysis_stream",
            requiresSummary: true,
            allowsResponseCapture: settings.llmProvider != .openai || settings.openAIAuthenticationMode != .chatGPTSubscription
        )
    }

    internal func streamChapterAnalysisEvents(
        from stream: AsyncThrowingStream<LLMStreamChunk, Error>,
        nameHint: String? = nil,
        requiresSummary: Bool = false,
        allowsResponseCapture: Bool = true
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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

                    if recordMode && allowsResponseCapture, let data = fullText.data(using: .utf8), !fullText.isEmpty {
                        recordResponse(data, name: nameHint ?? "chapter_analysis_stream")
                    }

                    let finalAnalysis: ChapterAnalysis
                    do {
                        finalAnalysis = try self.decodeStructured(ChapterAnalysis.self, from: fullText)
                    } catch {
                        throw LLMError.apiError("The provider completed, but its chapter analysis could not be decoded. Nothing was saved.")
                    }
                    if requiresSummary && finalAnalysis.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw ChapterAnalysisValidationError.emptyField("chapter summary")
                    }
                    continuation.yield(.completed(finalAnalysis))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func analyzeChapter(
        contentWithBlocks: String,
        rollingSummary: String?,
        bookTitle: String?,
        author: String?,
        settings: UserSettings
    ) async throws -> ChapterAnalysis {
        let stream = analyzeChapterStreaming(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            bookTitle: bookTitle,
            author: author,
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

    /// Context-only chapters use the reader's selected model and reasoning level.
    /// Classification preferences must not silently downgrade continuity.
    func generateSummary(
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> (summary: String, usage: TokenUsage?) {
        let prompt = PromptLibrary.summaryPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary
        )

        let provider = settings.llmProvider
        let model = SupportedModels.canonicalLLMModelID(settings.llmModel)

        let (response, usage): (SummaryResponse, TokenUsage?) = try await requestStructuredWithUsage(
            prompt: prompt,
            schema: SchemaLibrary.summaryOnly,
            provider: provider,
            model: model,
            apiKey: apiKey(for: provider, settings: settings),
            temperature: settings.temperature,
            reasoning: settings.insightReasoningLevel,
            nameHint: "chapter_summary",
            kind: .summary,
            authenticationMode: settings.openAIAuthenticationMode
        )

        let summary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw ChapterAnalysisValidationError.emptyField("chapter summary") }
        return (summary, usage)
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
            nameHint: "distill_search",
            kind: .other,
            authenticationMode: settings.openAIAuthenticationMode
        )
    }

    // MARK: - Chat (Streaming)

    func chatStreaming(
        message: String,
        previousTurns: [ChatTurn] = [],
        referenceTitle: String? = nil,
        referenceContent: String? = nil,
        contentWithBlocks: String,
        rollingSummary: String?,
        settings: UserSettings,
        onProviderState: (@MainActor (LLMConversationState) -> Void)? = nil
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let prompt = PromptLibrary.chatPrompt(
            message: message,
            previousTurns: previousTurns,
            referenceTitle: referenceTitle,
            referenceContent: referenceContent,
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
            nameHint: "chat_stream",
            kind: .chat,
            authenticationMode: settings.openAIAuthenticationMode,
            onProviderState: onProviderState
        )
    }

    // MARK: - Generate More Content

    func generateMoreInsightsStreaming(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingTitles: [String],
        settings: UserSettings,
        coveredIdeas: [String] = []
    ) -> AsyncThrowingStream<ChapterAnalysisStreamEvent, Error> {
        let prompt = PromptLibrary.moreInsightsPrompt(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummary,
            existingTitles: existingTitles,
            insightDensity: settings.insightDensity,
            coveredIdeas: coveredIdeas
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
            nameHint: "more_insights_stream",
            kind: .insight,
            authenticationMode: settings.openAIAuthenticationMode
        )

        return streamChapterAnalysisEvents(
            from: stream,
            nameHint: "more_insights_stream",
            allowsResponseCapture: settings.llmProvider != .openai || settings.openAIAuthenticationMode != .chatGPTSubscription
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
            webSearch: false,
            nameHint: "more_questions_stream",
            kind: .insight,
            authenticationMode: settings.openAIAuthenticationMode
        )

        return streamChapterAnalysisEvents(
            from: stream,
            nameHint: "more_questions_stream",
            allowsResponseCapture: settings.llmProvider != .openai || settings.openAIAuthenticationMode != .chatGPTSubscription
        )
    }

    // MARK: - Chapter Classification

    func classifyChapters(
        chapters: [(index: Int, title: String, preview: String)],
        settings: UserSettings
    ) async throws -> [Int: Bool] {
        let prompt = PromptLibrary.chapterClassificationPrompt(chapters: chapters)
        let (provider, model, key) = classificationModelSelection(settings: settings)

        let response: ClassificationResponse = try await requestStructured(
            prompt: prompt,
            schema: SchemaLibrary.chapterClassification,
            provider: provider,
            model: model,
            apiKey: key,
            temperature: 0.3,
            reasoning: .off,
            nameHint: "chapter_classification",
            kind: .other,
            authenticationMode: settings.openAIAuthenticationMode
        )

        let requestedIndices = Set(chapters.map(\.index))
        var result: [Int: Bool] = [:]
        for classification in response.classifications {
            guard requestedIndices.contains(classification.index),
                  result[classification.index] == nil,
                  ["content", "garbage"].contains(classification.type) else {
                throw LLMError.invalidResponse
            }
            result[classification.index] = classification.type == "garbage"
        }
        for chapter in chapters where result[chapter.index] == nil {
            result[chapter.index] = false
        }

        return result
    }

    /// Select the best model for classification (cheap and fast)
    func classificationModelSelection(settings: UserSettings) -> (LLMProvider, String, String) {
        let current = settings.llmProvider
        if current == .openai, settings.openAIAuthenticationMode == .chatGPTSubscription {
            let model = settings.useCheapestModelForClassification
                ? SupportedModels.utilityModel(for: .openai)
                : SupportedModels.canonicalLLMModelID(settings.llmModel)
            return (.openai, model, "")
        }
        if !settings.useCheapestModelForClassification, settings.hasAuthentication(for: current) {
            return (current, SupportedModels.canonicalLLMModelID(settings.llmModel), apiKey(for: current, settings: settings))
        }
        // Prefer the efficient Google utility model when available, otherwise stay with the selected provider.
        let candidates: [LLMProvider] = [.google, current, .anthropic, .openai]
        if let provider = candidates.first(where: { settings.hasAuthentication(for: $0) }) {
            return (provider, SupportedModels.utilityModel(for: provider), apiKey(for: provider, settings: settings))
        }
        return (current, SupportedModels.utilityModel(for: current), "")
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
        nameHint: String? = nil,
        kind: RequestKind,
        authenticationMode: OpenAIAuthenticationMode = .apiKey
    ) async throws -> String {
        let (text, _) = try await collectResponse(from: streamResponse(
            prompt: prompt, provider: provider, model: model, apiKey: apiKey,
            temperature: temperature, reasoning: reasoning, webSearch: webSearch,
            nameHint: nameHint, kind: kind, authenticationMode: authenticationMode
        ))
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
        nameHint: String? = nil,
        kind: RequestKind,
        authenticationMode: OpenAIAuthenticationMode = .apiKey
    ) async throws -> T {
        let (value, _): (T, TokenUsage?) = try await requestStructuredWithUsage(
            prompt: prompt, schema: schema, provider: provider, model: model, apiKey: apiKey,
            temperature: temperature, reasoning: reasoning, webSearch: webSearch,
            nameHint: nameHint, kind: kind, authenticationMode: authenticationMode
        )
        return value
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
        nameHint: String? = nil,
        kind: RequestKind,
        authenticationMode: OpenAIAuthenticationMode = .apiKey
    ) async throws -> (T, TokenUsage?) {
        let (text, usage) = try await collectResponse(from: streamResponse(
            prompt: prompt, provider: provider, model: model, apiKey: apiKey,
            temperature: temperature, reasoning: reasoning, schema: schema, webSearch: webSearch,
            nameHint: nameHint, kind: kind, authenticationMode: authenticationMode
        ))
        return (try decodeStructured(T.self, from: text), usage)
    }

    private func collectResponse(from stream: AsyncThrowingStream<StreamChunk, Error>) async throws -> (String, TokenUsage?) {
        var text = ""
        var usage: TokenUsage?
        for try await chunk in stream {
            switch chunk {
            case .content(let delta): text += delta
            case .thinking: break
            case .usage(let next):
                if let previous = usage {
                    usage = TokenUsage(
                        input: previous.input + next.input,
                        visibleOutput: previous.visibleOutput + next.visibleOutput,
                        cached: previous.cached.flatMap { before in next.cached.map { before + $0 } },
                        cacheWrite: previous.cacheWrite.flatMap { before in next.cacheWrite.map { before + $0 } },
                        reasoning: previous.reasoning.flatMap { before in next.reasoning.map { before + $0 } }
                    )
                } else {
                    usage = next
                }
            }
        }
        return (text, usage)
    }

    private func recordUsage(_ usage: TokenUsage, provider: LLMProvider, model: String, kind: RequestKind, subscription: Bool = false) {
        guard let appState = self.appState else { return }
        appState.addTokens(
            input: usage.input,
            reasoning: usage.reasoning ?? 0,
            output: usage.visibleOutput,
            cached: usage.cached,
            cacheWrite: usage.cacheWrite
        )
        if !subscription {
            appState.updateProcessingCost(
                inputTokens: usage.input,
                outputTokens: usage.visibleOutput,
                reasoningTokens: usage.reasoning ?? 0,
                cachedTokens: usage.cached ?? 0,
                cacheWriteTokens: usage.cacheWrite ?? 0,
                model: model
            )
        }

        var callUsage = LLMCallUsage(
            provider: subscription ? "OpenAI (ChatGPT)" : provider.rawValue,
            model: model,
            task: kind.ledgerTask,
            inputTokens: usage.input,
            outputTokens: usage.visibleOutput,
            reasoningTokens: usage.reasoning,
            cachedTokens: usage.cached,
            cacheWriteTokens: usage.cacheWrite,
            cost: subscription ? nil : LLMCallUsage.calculatedCost(for: usage, model: model)
        )
        do {
            try appState.database.saveLLMCallUsage(&callUsage)
        } catch {
            print("Failed to save LLM usage: \(error)")
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

    private func providerClient(for provider: LLMProvider, structuredOutputTool: Bool = false) -> any LLMProviderClient {
        switch provider {
        case .google:
            return GeminiProvider()
        case .openai:
            return OpenAIProvider()
        case .anthropic:
            return AnthropicProvider(structuredOutputTool: structuredOutputTool)
        }
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
        nameHint: String? = nil,
        kind: RequestKind,
        authenticationMode: OpenAIAuthenticationMode = .apiKey,
        onProviderState: (@MainActor (LLMConversationState) -> Void)? = nil
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let usesSubscription = provider == .openai && authenticationMode == .chatGPTSubscription
        let authRevision = subscriptionAuth.sessionRevision
        let admissionSettings = appState?.settings
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = SupportedModels.canonicalLLMModelID(model)
                    let currentLimiter = self.limiter
                    await currentLimiter.acquire(provider: provider, limit: appState?.settings.maxConcurrentRequests ?? 5)
                    defer { Task { await currentLimiter.release(provider: provider) } }
                    try Task.checkCancellation()
                    try validateAdmission(provider: provider, kind: kind, authenticationMode: authenticationMode, previous: admissionSettings)
                    if usesSubscription && authRevision != subscriptionAuth.sessionRevision { throw CancellationError() }
                    var credential = usesSubscription ? try await subscriptionAuth.credential() : nil
                    let key = credential?.accessToken ?? apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { throw LLMError.noAPIKey(provider) }
                    incrementInFlight(kind)
                    defer { decrementInFlight(kind) }

                    var client: any LLMProviderClient = provider == .openai
                        ? OpenAIProvider(subscriptionCredential: credential, sessionID: sessionID, apiKey: key)
                        : providerClient(for: provider, structuredOutputTool: provider == .anthropic && schema != nil && webSearch)
                    var request = try client.makeRequest(
                        prompt: prompt, model: model, apiKey: key, temperature: temperature,
                        reasoning: reasoning, schema: schema, stream: true, webSearch: webSearch
                    )
                    var nativeItems: [[String: Any]] = []
                    var continuations = 0
                    var refreshedCredential = false
                    while true {
                        try Task.checkCancellation()
                        let accumulator: LLMStreamAccumulator
                        do {
                            accumulator = try await consumeStream(
                                request, provider: provider, client: client, model: model, kind: kind,
                                nameHint: nameHint, subscription: usesSubscription,
                                buffersStructuredText: provider == .openai && schema != nil, continuation: continuation
                            )
                        } catch LLMError.httpError(401) {
                            guard let rejected = credential, !refreshedCredential else { throw LLMError.httpError(401) }
                            let renewed = try await subscriptionAuth.refreshCredential(rejectedAccessToken: rejected.accessToken)
                            try Task.checkCancellation()
                            try validateAdmission(provider: provider, kind: kind, authenticationMode: authenticationMode, previous: admissionSettings)
                            if authRevision != subscriptionAuth.sessionRevision { throw CancellationError() }
                            credential = renewed
                            refreshedCredential = true
                            client = OpenAIProvider(subscriptionCredential: renewed, sessionID: sessionID, apiKey: renewed.accessToken)
                            request.setValue("Bearer \(renewed.accessToken)", forHTTPHeaderField: "Authorization")
                            request.setValue(renewed.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                            request.setValue(renewed.residency, forHTTPHeaderField: "x-openai-internal-codex-residency")
                            continue
                        }
                        let state = try accumulator.conversationState(model: model, scope: client.conversationScope)
                        let items = try state.items(for: provider, model: model) ?? []
                        nativeItems.append(contentsOf: items)
                        if accumulator.needsContinuation {
                            guard webSearch, continuations < 4 else {
                                throw LLMError.apiError("Claude web search did not finish within the continuation limit.")
                            }
                            guard let data = request.httpBody,
                                  var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  var messages = body["messages"] as? [[String: Any]] else { throw LLMError.invalidResponse }
                            messages.append(contentsOf: items)
                            body["messages"] = messages
                            request.httpBody = try JSONSerialization.data(withJSONObject: body)
                            continuations += 1
                            continue
                        }
                        try Task.checkCancellation()
                        onProviderState?(LLMConversationState(
                            provider: provider, model: model, payload: try JSONSerialization.data(withJSONObject: nativeItems),
                            scope: client.conversationScope
                        ))
                        continuation.finish()
                        return
                    }
                } catch {
                    continuation.finish(throwing: usesSubscription ? subscriptionError(error) : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consumeStream(
        _ request: URLRequest,
        provider: LLMProvider,
        client: any LLMProviderClient,
        model: String,
        kind: RequestKind,
        nameHint: String?,
        subscription: Bool,
        buffersStructuredText: Bool,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws -> LLMStreamAccumulator {
        let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        if http.statusCode != 200 {
            if subscription { throw LLMError.httpError(http.statusCode) }
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw parseErrorMessage(from: data).map(LLMError.apiError) ?? LLMError.httpError(http.statusCode)
        }

        let recorder = recordMode && !subscription ? StreamingRecorder(name: nameHint ?? "stream") : nil
        var lines = SSELineParser()
        var events = SSEEventParser()
        var rawData = Data()
        var sawPayload = false
        var accumulator = LLMStreamAccumulator(provider: provider, structuredOutputTool: client.structuredOutputTool)
        var usage: TokenUsage?
        var emittedText = ""
        defer {
            // Incomplete, refused, and cancelled generations can still be billed.
            // Unknown counters stay unknown; each HTTP attempt is recorded once.
            if let usage = client.usage(fromResponse: accumulator.response) ?? usage {
                recordUsage(usage, provider: provider, model: model, kind: kind, subscription: subscription)
                continuation.yield(.usage(usage))
            }
            recorder?.save()
        }

        func handleEvent(_ payload: String) throws {
            sawPayload = true
            if payload == "[DONE]" { return }
            recorder?.recordChunk(payload)
            guard let data = payload.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.invalidResponse }
            if let next = client.observedUsage(fromStreamEvent: json) {
                if usage == nil { usage = next } else { usage?.mergeStreamingUsage(next) }
            }
            try accumulator.consume(json)
            if provider == .openai {
                for text in accumulator.openAIReasoningUpdates(json) { continuation.yield(.thinking(text)) }
                if accumulator.isComplete { return }
            }
            try client.handleStreamEvent(json) { chunk in
                if provider == .openai && chunk.isThinking { return }
                if case .content(let text) = chunk {
                    guard !client.structuredOutputTool, !buffersStructuredText else { return }
                    if provider == .openai && !accumulator.includesOpenAITextDelta(json) { return }
                    emittedText += text
                }
                continuation.yield(chunk)
            }
        }
        func handleLine(_ line: String) throws {
            try events.append(line: line, onEvent: handleEvent)
        }
        var iterator = bytes.makeAsyncIterator()
        while true {
            let next: UInt8?
            do {
                next = try await iterator.next()
            } catch {
                try Task.checkCancellation()
                // Gemini may send usage after STOP. A subsequent socket failure must
                // not invalidate that completed candidate, but explicit API errors do.
                if provider == .google && accumulator.isComplete { break }
                throw error
            }
            guard let byte = next else { break }
            try Task.checkCancellation()
            if !sawPayload { rawData.append(byte) }
            try lines.append(byte: byte, onLine: handleLine)
            // OpenAI response.completed and Claude message_stop are terminal.
            // Gemini stays open for its optional trailing usage-only event.
            if provider != .google && accumulator.isComplete { break }
        }
        try lines.finalize(onLine: handleLine)
        try events.finalize(onEvent: handleEvent)
        if !sawPayload {
            guard let json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                throw LLMError.invalidResponse
            }
            usage = client.usage(fromResponse: json)
            try accumulator.consumeResponse(json)
            if provider == .openai {
                for text in accumulator.openAIReasoningUpdates(["type": "response.completed"]) {
                    continuation.yield(.thinking(text))
                }
            }
        }
        try accumulator.finish()
        let finalText = accumulator.visibleText
        if !accumulator.needsContinuation && finalText.isEmpty { throw LLMError.invalidResponse }
        guard finalText.utf8.starts(with: emittedText.utf8) else { throw LLMError.invalidResponse }
        let remainder = finalText.utf8.dropFirst(emittedText.utf8.count)
        if !remainder.isEmpty { continuation.yield(.content(String(decoding: remainder, as: UTF8.self))) }
        try Task.checkCancellation()
        return accumulator
    }

    private func validateAdmission(
        provider: LLMProvider, kind: RequestKind, authenticationMode: OpenAIAuthenticationMode,
        previous: UserSettings?
    ) throws {
        guard let previous, let settings = appState?.settings else { return }
        if provider == .openai && previous.openAIAuthenticationMode != settings.openAIAuthenticationMode { throw CancellationError() }
        if !(provider == .openai && authenticationMode == .chatGPTSubscription),
           apiKey(for: provider, settings: previous) != apiKey(for: provider, settings: settings) {
            throw CancellationError()
        }
        switch kind {
        case .summary, .insight, .chat:
            guard previous.llmProvider == settings.llmProvider,
                  previous.llmModel == settings.llmModel else { throw CancellationError() }
        case .other: break
        }
    }

    private func subscriptionError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is OpenAISubscriptionAuthError { return error }
        if let failure = error as? LLMError, case .httpError(let status) = failure {
            switch status {
            case 401: return LLMError.apiError("ChatGPT rejected this session. Sign in again in Settings.")
            case 403: return LLMError.apiError("This ChatGPT account or workspace cannot access the requested model.")
            case 429: return LLMError.apiError("ChatGPT subscription usage or rate limit reached. No paid API fallback was used.")
            default: return LLMError.apiError("ChatGPT subscription request failed (HTTP \(status)).")
            }
        }
        if let failure = error as? LLMError, case .invalidResponse = failure {
            return LLMError.apiError("ChatGPT returned an invalid completion. No analysis was saved. No paid API fallback was used.")
        }
        return LLMError.apiError("ChatGPT generation did not complete. No analysis was saved. No paid API fallback was used.")
    }

    private func incrementInFlight(_ kind: RequestKind) {
        guard let appState = self.appState else { return }
        Task { @MainActor in
            guard appState.isProcessingBook else { return }
            switch kind {
            case .summary: appState.processingInFlightSummaries += 1
            case .insight: appState.processingInFlightInsights += 1
            case .chat, .other: break
            }
        }
    }

    private func decrementInFlight(_ kind: RequestKind) {
        guard let appState = self.appState else { return }
        Task { @MainActor in
            guard appState.isProcessingBook else { return }
            switch kind {
            case .summary: appState.processingInFlightSummaries = max(0, appState.processingInFlightSummaries - 1)
            case .insight: appState.processingInFlightInsights = max(0, appState.processingInFlightInsights - 1)
            case .chat, .other: break
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
