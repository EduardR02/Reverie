import XCTest
import GRDB
@testable import Reverie

final class LLMServiceTests: XCTestCase {
    var llmService: LLMService!
    var mockSession: URLSession!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
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
                "finishReason": "STOP",
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
                "finishReason": "STOP",
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
                "finishReason": "STOP",
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
                "finishReason": "STOP",
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
                "finishReason": "STOP",
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
        let appState = AppState(database: database, settings: UserSettings())
        llmService.setAppState(appState)

        let jsonResponse = """
        {
            "candidates": [{
                "finishReason": "STOP",
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
        XCTAssertEqual(rows[0].model, SupportedModels.utilityModel(for: .google))
        XCTAssertEqual(rows[0].task, "other")
        XCTAssertEqual(rows[0].inputTokens, 1000)
        XCTAssertEqual(rows[0].outputTokens, 100)
        XCTAssertEqual(rows[0].reasoningTokens, 25)
        XCTAssertNotNil(rows[0].cost)
    }

    @MainActor
    func testGeminiNonStreamingUsageIncludesCachedContentTokenCount() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database, settings: UserSettings())
        llmService.setAppState(appState)

        let jsonResponse = """
        {
            "candidates": [{
                "finishReason": "STOP",
                "content": { "parts": [{ "text": "query text" }] }
            }],
            "usageMetadata": { "promptTokenCount": 1000, "candidatesTokenCount": 100, "thoughtsTokenCount": 25, "cachedContentTokenCount": 300 }
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
        XCTAssertEqual(rows[0].inputTokens, 1000)
        XCTAssertEqual(rows[0].outputTokens, 100)
        XCTAssertEqual(rows[0].reasoningTokens, 25)
        XCTAssertEqual(rows[0].cachedTokens, 300)
    }

    @MainActor
    func testAnthropicNonStreamingUsageIncludesCacheReadInTotalInput() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database, settings: UserSettings())
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
        let appState = AppState(database: database, settings: UserSettings())
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
    func testGeminiStreamingWithoutFinishReasonRejectsPartialAnswer() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database, settings: UserSettings())
        llmService.setAppState(appState)

        let streamResponse = """
        data: {"candidates":[{"content":{"parts":[{"text":"Hel"}]}}],"usageMetadata":{"promptTokenCount":1000,"candidatesTokenCount":4,"thoughtsTokenCount":10,"cachedContentTokenCount":200}}

        data: {"candidates":[{"content":{"parts":[{"text":"lo"}]}}],"usageMetadata":{"promptTokenCount":1000,"candidatesTokenCount":8,"thoughtsTokenCount":20,"cachedContentTokenCount":200}}

        """
        MockURLProtocol.stubResponseData = streamResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )

        var settings = UserSettings()
        settings.llmProvider = .google
        settings.googleAPIKey = "mock-key"

        let stream = llmService.chatStreaming(
            message: "What happened?",
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: nil,
            settings: settings
        )

        var text = ""
        var emittedUsages: [LLMService.TokenUsage] = []
        do {
            for try await chunk in stream {
                switch chunk {
                case .content(let part): text += part
                case .usage(let usage): emittedUsages.append(usage)
                case .thinking: break
                }
            }
            XCTFail("A disconnected stream is not a completed answer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("before generation completed"))
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(emittedUsages.count, 1)
        let reported = try XCTUnwrap(emittedUsages.first)
        XCTAssertEqual(reported.input, 1000)
        XCTAssertEqual(reported.visibleOutput, 8)
        XCTAssertEqual(reported.reasoning, 20)
        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.inputTokens, 1000)
        XCTAssertEqual(row.cachedTokens, 200)
        XCTAssertEqual(row.outputTokens, 8)
        XCTAssertEqual(row.reasoningTokens, 20)
    }

    @MainActor
    func testAnthropicStreamingUsageMergesMessageStartAndMessageDelta() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database, settings: UserSettings())
        llmService.setAppState(appState)

        let streamResponse = """
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","stop_reason":null,"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400,"output_tokens":5}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":80}}

        data: {"type":"message_stop"}

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
        XCTAssertEqual(emittedUsages.count, 1)
        let reported = try XCTUnwrap(emittedUsages.first)
        XCTAssertEqual(reported.input, 1900)
        XCTAssertEqual(reported.cached, 400)
        XCTAssertEqual(reported.cacheWrite, 300)
        XCTAssertEqual(reported.visibleOutput, 80)
        XCTAssertNil(reported.reasoning)
        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, LLMProvider.anthropic.rawValue)
        XCTAssertEqual(rows[0].model, SupportedModels.Anthropic.sonnet45)
        XCTAssertEqual(rows[0].inputTokens, 1900)
        XCTAssertEqual(rows[0].cachedTokens, 400)
        XCTAssertEqual(rows[0].outputTokens, 80)
        XCTAssertNil(rows[0].reasoningTokens)
        XCTAssertNotNil(rows[0].cost)
        XCTAssertEqual(emittedUsages.reduce(0) { $0 + $1.input }, rows[0].inputTokens)
        XCTAssertEqual(emittedUsages.reduce(0) { $0 + $1.visibleOutput }, rows[0].outputTokens)
        XCTAssertEqual(rows[0].cost ?? 0, 0.006045, accuracy: 0.000001)
    }

    @MainActor
    func testFailedStreamingCallPreservesReportedUsage() async throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        let appState = AppState(database: database, settings: UserSettings())
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

        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        let reported = try XCTUnwrap(rows.first)
        XCTAssertEqual(reported.inputTokens, 1200)
        XCTAssertEqual(reported.outputTokens, 0)
        XCTAssertEqual(reported.cachedTokens, 0)
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

    @MainActor
    func testTerminalSnapshotCompletesMissingTextWithoutDuplicatingDeltas() async throws {
        var settings = UserSettings()
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.gpt61Sol
        settings.openAIAPIKey = "synthetic-key"
        for (delta, final) in [("", "Terminal answer"), ("Hello ", "Hello 🌍"), ("e", "e\u{301}vidence")] {
            let response: [String: Any] = [
                "status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": final]]]],
                "usage": ["input_tokens": 100, "output_tokens": 10]
            ]
            var events: [[String: Any]] = []
            if !delta.isEmpty { events.append(["type": "response.output_text.delta", "delta": delta]) }
            events.append(["type": "response.completed", "response": response])
            let data = try events.map { "data: \(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self))\n\n" }.joined()
            MockURLProtocol.stubResponseData = Data(data.utf8)
            MockURLProtocol.stubResponse = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])
            var text = ""
            var usages: [LLMService.TokenUsage] = []
            for try await chunk in llmService.chatStreaming(message: "Explain", contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings) {
                switch chunk {
                case .content(let part): text += part
                case .usage(let usage): usages.append(usage)
                case .thinking: break
                }
            }
            XCTAssertEqual(text, final)
            XCTAssertEqual(usages.count, 1)
            XCTAssertEqual(usages.first?.total, 110)
        }
    }

    @MainActor
    func testBilledIncompleteAndFailedResponsesPreserveCacheUsageExactlyOnce() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        var settings = UserSettings()
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.gpt61Sol
        settings.openAIAPIKey = "synthetic-key"
        let state = AppState(database: database, settings: settings)
        llmService.setAppState(state)
        for status in ["incomplete", "failed"] {
            let response: [String: Any] = [
                "status": status, "output": [],
                "incomplete_details": ["reason": "max_output_tokens"],
                "error": ["message": "Generation failed"],
                "usage": [
                    "input_tokens": 1000, "output_tokens": 50,
                    "input_tokens_details": ["cached_tokens": 600, "cache_write_tokens": 100],
                    "output_tokens_details": ["reasoning_tokens": 40]
                ]
            ]
            let event: [String: Any] = ["type": "response.\(status)", "response": response]
            MockURLProtocol.stubResponseData = Data("data: \(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))\n\n".utf8)
            MockURLProtocol.stubResponse = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])
            var usageCount = 0
            do {
                for try await chunk in llmService.chatStreaming(message: "Explain", contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings) {
                    if case .usage = chunk { usageCount += 1 }
                }
                XCTFail("An unsuccessful response must not be accepted")
            } catch {
                XCTAssertTrue(error is LLMService.LLMError)
            }
            XCTAssertEqual(usageCount, 1)
        }
        let rows = try database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.inputTokens, 1000)
            XCTAssertEqual(row.outputTokens, 10)
            XCTAssertEqual(row.reasoningTokens, 40)
            XCTAssertEqual(row.cachedTokens, 600)
            XCTAssertEqual(row.cacheWriteTokens, 100)
        }
        XCTAssertEqual(state.readingStats.tokensInput, 2000)
        XCTAssertEqual(state.readingStats.tokensCached, 1200)
        XCTAssertEqual(state.readingStats.tokensCacheWrite, 200)
        XCTAssertEqual(state.readingStats.totalTokens, 2100)
    }

    @MainActor
    func testSparseClassificationIndicesAndUnknownResultsRespectRequestedChapters() async throws {
        var settings = UserSettings()
        settings.googleAPIKey = "synthetic-key"
        let chapters = [(index: 4, title: "Preface", preview: "Notes"), (index: 9, title: "Chapter", preview: "Story")]
        for (classifications, valid) in [
            ([["index": 4, "type": "garbage"]], true),
            ([["index": 0, "type": "garbage"]], false),
            ([["index": 4, "type": "garbage"], ["index": 4, "type": "content"]], false),
            ([["index": 4, "type": "unknown"]], false)
        ] {
            let result = String(decoding: try JSONSerialization.data(withJSONObject: ["classifications": classifications]), as: UTF8.self)
            let response: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": result]]]]]]
            MockURLProtocol.stubResponseData = try JSONSerialization.data(withJSONObject: response)
            MockURLProtocol.stubResponse = HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            do {
                let result = try await llmService.classifyChapters(chapters: chapters, settings: settings)
                XCTAssertTrue(valid)
                XCTAssertEqual(result, [4: true, 9: false])
            } catch {
                XCTAssertFalse(valid)
                XCTAssertTrue(error is LLMService.LLMError)
            }
        }
    }

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
