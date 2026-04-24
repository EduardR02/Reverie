import XCTest
import GRDB
@testable import Reverie

final class LLMServiceTests: XCTestCase {
    var llmService: LLMService!
    var mockSession: URLSession!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        llmService = LLMService(session: mockSession)
        llmService.recordMode = false
    }

    @MainActor
    override func tearDown() async throws {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    @MainActor
    func testAnalyzeChapterSuccess() async throws {
        let jsonResponse = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "{'summary': 'Test Summary', 'annotations': [], 'quizQuestions': [], 'imageSuggestions': []}"
                    }]
                }
            }],
            "usageMetadata": { "promptTokenCount": 100, "candidatesTokenCount": 50 }
        }
        """.replacingOccurrences(of: "'", with: "\\\"")
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"
        let analysis = try await llmService.analyzeChapter(
            contentWithBlocks: "Some content",
            rollingSummary: nil,
            bookTitle: nil,
            author: nil,
            settings: settings
        )


        XCTAssertEqual(analysis.summary, "Test Summary")
    }

    @MainActor
    func testAnalyzeChapterStreamingFallback() async throws {
        let jsonResponse = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "{'summary': 'Streamed Summary', 'annotations': [], 'quizQuestions': [], 'imageSuggestions': []}"
                    }]
                }
            }],
            "usageMetadata": { "promptTokenCount": 100, "candidatesTokenCount": 50 }
        }
        """.replacingOccurrences(of: "'", with: "\\\"")
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"
        let stream = llmService.analyzeChapterStreaming(
            contentWithBlocks: "Some content",
            rollingSummary: nil,
            bookTitle: nil,
            author: nil,
            settings: settings
        )

        var finalAnalysis: LLMService.ChapterAnalysis?
        for try await event in stream {
            if case .completed(let analysis) = event {
                finalAnalysis = analysis
            }
        }

        XCTAssertEqual(finalAnalysis?.summary, "Streamed Summary")
    }

    @MainActor
    func testDistillSearchQuerySuccess() async throws {
        let jsonResponse = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "Refined Search Query"
                    }]
                }
            }]
        }
        """
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"
        let query = try await llmService.distillSearchQuery(
            insightTitle: "Title",
            insightContent: "Content",
            bookTitle: "Book",
            author: "Author",
            settings: settings
        )

        XCTAssertEqual(query, "Refined Search Query")
    }

    @MainActor
    func testRewriteImagePromptSuccess() async throws {
        let jsonResponse = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "  safe cinematic city skyline at dusk  "
                    }]
                }
            }]
        }
        """
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"

        let rewritten = try await llmService.rewriteImagePrompt(
            originalPrompt: "A violent battle scene with gore",
            refusalReason: "Policy violation",
            settings: settings
        )

        XCTAssertEqual(rewritten, "safe cinematic city skyline at dusk")
    }

    @MainActor
    func testAnalyzeChapterDecodesImageSuggestionAspectRatio() async throws {
        let jsonResponse = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "{\\\"summary\\\": \\\"Test Summary\\\", \\\"annotations\\\": [], \\\"quizQuestions\\\": [], \\\"imageSuggestions\\\": [{\\\"excerpt\\\": \\\"A narrow tower over the city.\\\", \\\"sourceBlockId\\\": 3, \\\"aspectRatio\\\": \\\"9:16\\\"}]}"
                    }]
                }
            }],
            "usageMetadata": { "promptTokenCount": 100, "candidatesTokenCount": 50 }
        }
        """
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"
        let analysis = try await llmService.analyzeChapter(
            contentWithBlocks: "Some content",
            rollingSummary: nil,
            bookTitle: nil,
            author: nil,
            settings: settings
        )

        XCTAssertEqual(analysis.imageSuggestions.first?.aspectRatio, "9:16")
    }

    @MainActor
    func testNonStreamingUsagePersistsLedgerRow() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database)
        llmService.setAppState(appState)

        let jsonResponse = """
        {
            "candidates": [{
                "content": { "parts": [{ "text": "query text" }] }
            }],
            "usageMetadata": { "promptTokenCount": 1000, "candidatesTokenCount": 100, "thoughtsTokenCount": 25 }
        }
        """
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"

        _ = try await llmService.distillSearchQuery(
            insightTitle: "Title",
            insightContent: "Content",
            bookTitle: "Book",
            author: "Author",
            settings: settings
        )

        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, LLMProvider.google.rawValue)
        XCTAssertEqual(rows[0].model, SupportedModels.Google.gemini3FlashPreview)
        XCTAssertEqual(rows[0].task, "other")
        XCTAssertEqual(rows[0].inputTokens, 1000)
        XCTAssertEqual(rows[0].outputTokens, 100)
        XCTAssertEqual(rows[0].reasoningTokens, 25)
        XCTAssertNotNil(rows[0].cost)
    }

    @MainActor
    func testAnthropicNonStreamingUsageIncludesCacheReadInTotalInput() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database)
        llmService.setAppState(appState)

        let jsonResponse = """
        {
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "content": [{ "type": "text", "text": "query text" }],
            "model": "claude-sonnet-4-5",
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": 1200,
                "cache_creation_input_tokens": 300,
                "cache_read_input_tokens": 400,
                "output_tokens": 80
            }
        }
        """
        MockURLProtocol.stubResponseData = jsonResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.llmProvider = .anthropic
        settings.llmModel = SupportedModels.Anthropic.sonnet45
        settings.anthropicAPIKey = "mock-key"
        settings.useCheapestModelForClassification = false

        _ = try await llmService.distillSearchQuery(
            insightTitle: "Title",
            insightContent: "Content",
            bookTitle: "Book",
            author: "Author",
            settings: settings
        )

        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, LLMProvider.anthropic.rawValue)
        XCTAssertEqual(rows[0].model, SupportedModels.Anthropic.sonnet45)
        XCTAssertEqual(rows[0].inputTokens, 1900)
        XCTAssertEqual(rows[0].cachedTokens, 400)
        XCTAssertEqual(rows[0].outputTokens, 80)
    }

    @MainActor
    func testStreamingUsagePersistsLedgerRowOnceWhenConsumerIgnoresUsage() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database)
        llmService.setAppState(appState)

        let streamResponse = """
        data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}

        data: {"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":40,"candidatesTokenCount":8,"thoughtsTokenCount":3}}

        """
        MockURLProtocol.stubResponseData = streamResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"

        let stream = llmService.chatStreaming(
            message: "What happened?",
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: "Prior context",
            settings: settings
        )

        var text = ""
        for try await chunk in stream {
            if case .content(let part) = chunk {
                text += part
            }
        }

        XCTAssertEqual(text, "Hello")
        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inputTokens, 40)
        XCTAssertEqual(rows[0].outputTokens, 8)
        XCTAssertEqual(rows[0].reasoningTokens, 3)
        XCTAssertEqual(rows[0].task, "chat")
    }

    @MainActor
    func testAnthropicStreamingUsageMergesMessageStartAndMessageDelta() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database)
        llmService.setAppState(appState)

        let streamResponse = """
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","stop_reason":null,"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400,"output_tokens":5}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":80,"reasoning_tokens":7}}

        """
        MockURLProtocol.stubResponseData = streamResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )

        var settings = UserSettings()
        settings.llmProvider = .anthropic
        settings.llmModel = SupportedModels.Anthropic.sonnet45
        settings.anthropicAPIKey = "mock-key"

        let stream = llmService.chatStreaming(
            message: "Question?",
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: nil,
            settings: settings
        )

        var text = ""
        var emittedUsages: [LLMService.TokenUsage] = []
        for try await chunk in stream {
            if case .content(let part) = chunk {
                text += part
            } else if case .usage(let usage) = chunk {
                emittedUsages.append(usage)
            }
        }

        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(emittedUsages.count, 2)
        XCTAssertEqual(emittedUsages[0].input, 1900)
        XCTAssertEqual(emittedUsages[0].cached, 400)
        XCTAssertEqual(emittedUsages[0].cacheWrite, 300)
        XCTAssertEqual(emittedUsages[0].visibleOutput, 0)
        XCTAssertEqual(emittedUsages[1].input, 0)
        XCTAssertEqual(emittedUsages[1].visibleOutput, 80)
        XCTAssertEqual(emittedUsages[1].reasoning, 7)
        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, LLMProvider.anthropic.rawValue)
        XCTAssertEqual(rows[0].model, SupportedModels.Anthropic.sonnet45)
        XCTAssertEqual(rows[0].inputTokens, 1900)
        XCTAssertEqual(rows[0].cachedTokens, 400)
        XCTAssertEqual(rows[0].outputTokens, 80)
        XCTAssertEqual(rows[0].reasoningTokens, 7)
        XCTAssertNotNil(rows[0].cost)
        XCTAssertEqual(emittedUsages.reduce(0) { $0 + $1.input }, rows[0].inputTokens)
        XCTAssertEqual(emittedUsages.reduce(0) { $0 + $1.visibleOutput }, rows[0].outputTokens)
        XCTAssertEqual(rows[0].cost ?? 0, 0.00615, accuracy: 0.000001)
    }

    @MainActor
    func testFailedStreamingCallDoesNotPersistLedgerRow() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database)
        llmService.setAppState(appState)

        let streamResponse = """
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","usage":{"input_tokens":1200,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        data: {"type":"error","error":{"type":"overloaded_error","message":"model overloaded"}}

        """
        MockURLProtocol.stubResponseData = streamResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )

        var settings = UserSettings()
        settings.llmProvider = .anthropic
        settings.llmModel = SupportedModels.Anthropic.sonnet45
        settings.anthropicAPIKey = "mock-key"

        let stream = llmService.chatStreaming(
            message: "Question?",
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: nil,
            settings: settings
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected streaming error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("model overloaded"))
        }

        XCTAssertEqual(try database.fetchLLMCallUsage().count, 0)
    }

    @MainActor
    func testBookProcessorImageLiveCostAccumulatesWithExistingTextCost() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let appState = AppState(database: database)
        appState.llmService = LLMService(appState: appState, session: mockSession)
        appState.imageService = ImageService(session: mockSession)
        appState.settings.googleAPIKey = "mock-key"
        appState.settings.llmProvider = .google
        appState.settings.llmModel = SupportedModels.Google.gemini3FlashPreview
        appState.settings.useCheapestModelForClassification = true
        appState.settings.imagesEnabled = true
        appState.settings.imageModel = .gemini25Flash
        appState.settings.webSearchEnabled = false
        appState.settings.insightReasoningLevel = .off
        appState.settings.maxConcurrentRequests = 1

        var book = Book(title: "Book", author: "Author", epubPath: "book.epub", chapterCount: 1)
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter 1", contentHTML: "<p>Chapter text.</p>", wordCount: 2)
        try database.saveChapter(&chapter)

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains(":streamGenerateContent") {
                return (response, Self.analysisStreamResponse.data(using: .utf8)!)
            }
            if url.contains(ImageModel.gemini25Flash.apiModel) {
                let data = #"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/jpeg","data":"aW1hZ2U="}}]}}]}"#.data(using: .utf8)!
                return (response, data)
            }

            return (response, Self.summaryResponse.data(using: .utf8)!)
        }

        let processor = BookProcessor(appState: appState, book: book)
        await processor.process()

        let summaryInputCost = (1000.0 / 1_000_000.0) * 0.5
        let summaryOutputCost = (100.0 / 1_000_000.0) * 3.0
        let insightInputCost = (2000.0 / 1_000_000.0) * 0.5
        let insightOutputCost = (350.0 / 1_000_000.0) * 3.0
        let textCost = summaryInputCost + summaryOutputCost + insightInputCost + insightOutputCost
        let imageCost = LLMCallUsage.calculatedImageCost(for: .gemini25Flash)!

        XCTAssertEqual(appState.processingCostEstimate, textCost + imageCost, accuracy: 0.000001)
    }

    @MainActor
    func testHandleAPIError() async throws {
        let errorJson = """
        {
            "error": {
                "message": "Quota exceeded",
                "code": 429
            }
        }
        """
        MockURLProtocol.stubResponseData = errorJson.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )

        var settings = UserSettings()
        settings.googleAPIKey = "mock-key"
        do {
            _ = try await llmService.analyzeChapter(
                contentWithBlocks: "Some content",
                rollingSummary: nil,
                bookTitle: nil,
                author: nil,
                settings: settings
            )
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Quota exceeded"))
        }
    }

    private static let summaryResponse = """
    {
        "candidates": [{
            "content": { "parts": [{ "text": "{\\\"summary\\\":\\\"Short summary\\\"}" }] }
        }],
        "usageMetadata": { "promptTokenCount": 1000, "candidatesTokenCount": 100 }
    }
    """

    private static let analysisStreamResponse = """
    data: {"candidates":[{"content":{"parts":[{"text":"{\\\"summary\\\":\\\"Insight summary\\\",\\\"annotations\\\":[],\\\"quizQuestions\\\":[],\\\"imageSuggestions\\\":[{\\\"excerpt\\\":\\\"A river at dawn\\\",\\\"sourceBlockId\\\":1}]}"}]}}]}

    data: {"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":2000,"candidatesTokenCount":300,"thoughtsTokenCount":50}}

    """
}

// MARK: - Mock Infrastructure

@MainActor
class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubResponseData: Data?
    nonisolated(unsafe) static var stubResponse: URLResponse?
    nonisolated(unsafe) static var stubError: Error?
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (URLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        
        if let error = MockURLProtocol.stubError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let handler = MockURLProtocol.requestHandler {
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if let response = MockURLProtocol.stubResponse {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let data = MockURLProtocol.stubResponseData {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
