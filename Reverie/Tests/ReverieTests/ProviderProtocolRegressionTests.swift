import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ProviderProtocolRegressionTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try providerRequestJSON(request)
    }

    private func request(_ provider: any LLMProviderClient, model: String, prompt: LLMRequestPrompt = LLMRequestPrompt(text: "Read closely"), reasoning: ReasoningLevel = .high, schema: LLMStructuredSchema? = nil, search: Bool = false) throws -> URLRequest {
        try provider.makeRequest(prompt: prompt, model: model, apiKey: "fixture-key", temperature: 0.7, reasoning: reasoning, schema: schema, stream: true, webSearch: search)
    }

    func testSparseOpenAIItemsPreserveNativeStateAndOnlyFinalAnswerIsVisible() throws {
        var state = LLMStreamAccumulator(provider: .openai)
        let reasoning: [String: Any] = ["id": "rs_1", "type": "reasoning", "encrypted_content": "opaque", "summary": [["type": "summary_text", "text": "Visible summary."]]]
        let items: [[String: Any]] = [
            reasoning,
            ["id": "progress", "type": "message", "phase": "commentary", "content": [["type": "output_text", "text": "Researching"]]],
            ["id": "answer", "type": "message", "phase": "final_answer", "content": [["type": "output_text", "text": "Final answer"]]]
        ]
        for (index, item) in items.enumerated() {
            try state.consume(["type": "response.output_item.done", "output_index": index, "item": item])
        }
        XCTAssertThrowsError(try state.finish(), "Completed items are not a completed response")
        try state.consume(["type": "response.completed", "response": ["id": "resp_sparse"]])
        try state.finish()
        XCTAssertEqual(state.visibleText, "Final answer")
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.OpenAI.gpt61Sol).items(for: .openai, model: SupportedModels.OpenAI.gpt61Sol))
        XCTAssertEqual(native.count, 3)
        XCTAssertEqual(native.first?["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(native[1]["phase"] as? String, "commentary")
        XCTAssertEqual(native[2]["phase"] as? String, "final_answer")
    }

    func testSparseOpenAICompletionDoesNotHideUnfinishedToolsMessagesOrTurns() throws {
        let invalidItems: [[String: Any]] = [
            ["type": "function_call", "name": "unavailable", "arguments": "{}"],
            ["type": "web_search_call", "status": "failed"],
            ["type": "message", "status": "in_progress", "content": [["type": "output_text", "text": "Partial"]]],
            ["type": "message", "content": [["type": "refusal", "refusal": "Refused"]]]
        ]
        for item in invalidItems {
            var state = LLMStreamAccumulator(provider: .openai)
            try state.consume(["type": "response.output_item.done", "item": item])
            XCTAssertThrowsError(try state.consume(["type": "response.completed", "response": ["id": "bad", "usage": ["input_tokens": 10, "output_tokens": 2]]]))
            XCTAssertFalse(state.isComplete)
            XCTAssertEqual(OpenAIProvider().usage(fromResponse: state.response)?.total, 12)
        }
        var turn = LLMStreamAccumulator(provider: .openai)
        XCTAssertThrowsError(try turn.consume(["type": "response.completed", "response": ["id": "partial-turn", "end_turn": false]]))
        var openItem = LLMStreamAccumulator(provider: .openai)
        try openItem.consume(["type": "response.output_item.added", "output_index": 0, "item": ["id": "message", "type": "message", "content": []]])
        XCTAssertThrowsError(try openItem.consume(["type": "response.completed", "response": ["id": "missing-item-done"]]))
        XCTAssertThrowsError(try openItem.finish())
    }

    func testOpenAIReasoningSnapshotsFillSparsePartsWithoutRepeatingDeltasOrCiphertext() throws {
        var state = LLMStreamAccumulator(provider: .openai)
        let events: [[String: Any]] = [
            ["type": "response.reasoning_summary_text.delta", "item_id": "rs", "summary_index": 0, "delta": "First "],
            ["type": "response.reasoning_summary_text.done", "item_id": "rs", "summary_index": 0, "text": "First part."],
            ["type": "response.reasoning_summary_part.done", "item_id": "rs", "summary_index": 0, "part": ["text": "First part."]],
            ["type": "response.reasoning_summary_text.done", "item_id": "rs", "summary_index": 1, "text": "Second part."],
            ["type": "response.output_item.done", "output_index": 0, "item": ["id": "rs", "type": "reasoning", "encrypted_content": "never-display", "summary": [["text": "First part."], ["text": "Second part."]]]],
            ["type": "response.completed", "response": ["id": "reasoning-complete"]]
        ]
        var display = ""
        for event in events {
            try state.consume(event)
            display += state.openAIReasoningUpdates(event).joined()
        }
        XCTAssertEqual(display, "First part.\n\nSecond part.")
        var terminalOnly = LLMStreamAccumulator(provider: .openai)
        let terminal: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [["id": "rs_only", "type": "reasoning", "encrypted_content": "never-display", "summary": [["text": "Terminal summary."]]]]]]
        try terminalOnly.consume(terminal)
        XCTAssertEqual(terminalOnly.openAIReasoningUpdates(terminal).joined(), "Terminal summary.")
    }

    func testEveryProviderFinalizesImagesOffAnalysisThroughAtomicChapterPersistence() async throws {
        let analysis = #"{"annotations":[{"type":"science","title":"Curvature","content":"Gravity is geometric.","sourceBlockId":1}],"quizQuestions":[],"summary":"Gravity curves spacetime."}"#
        let cases: [(LLMProvider, String, [[String: Any]])] = [
            (.openai, SupportedModels.OpenAI.gpt61Sol, [
                ["type": "response.output_item.done", "output_index": 0, "item": ["id": "msg", "type": "message", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": analysis]]]],
                ["type": "response.completed", "response": ["id": "resp", "usage": ["input_tokens": 100, "output_tokens": 20]]]
            ]),
            (.anthropic, SupportedModels.Anthropic.opus55, [
                ["type": "message_start", "message": ["role": "assistant", "content": [], "usage": ["input_tokens": 100, "output_tokens": 1]]],
                ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Check the passage."]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "opaque"]],
                ["type": "content_block_stop", "index": 0],
                ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "submit_fixture", "name": AnthropicProvider.structuredOutputToolName, "input": [:]]],
                ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": analysis]],
                ["type": "content_block_stop", "index": 1],
                ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 20]],
                ["type": "message_stop"]
            ]),
            (.google, SupportedModels.Google.gemini38Flash, [
                ["candidates": [["content": ["parts": [["thought": true, "text": "Check the passage."]]]]]],
                ["candidates": [["content": ["parts": [["text": analysis]]]]]],
                ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "", "thoughtSignature": "opaque"]]]]]],
                ["usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20]]
            ])
        ]
        for (provider, model, events) in cases {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 10
            config.protocolClasses = [ProviderProtocolURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
            let payload = try events.map { "data: \(String(decoding: try json($0), as: UTF8.self))\n\n" }.joined()
            ProviderProtocolURLProtocol.setHandler { request in
                let headers = provider == .google
                    ? ["Content-Type": "text/event-stream"]
                    : ["Content-Type": "text/event-stream", "X-Fixture-Open": "1"]
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, Data(payload.utf8))
            }
            var settings = UserSettings()
            settings.llmProvider = provider
            settings.llmModel = model
            settings.imagesEnabled = false
            settings.webSearchEnabled = true
            settings.openAIAPIKey = "fixture-key"
            settings.anthropicAPIKey = "fixture-key"
            settings.googleAPIKey = "fixture-key"
            let database = try DatabaseService(dbQueue: DatabaseQueue())
            let state = AppState(database: database, settings: settings)
            let service = LLMService(appState: state, session: session)
            var book = Book(title: "Gravity", author: "Fixture", epubPath: "")
            try database.saveBook(&book)
            var chapter = Chapter(bookId: book.id!, index: 0, title: "Curvature", contentHTML: "<p>Gravity curves spacetime.</p>")
            try database.saveChapter(&chapter)
            let analyzer = ChapterAnalyzer(llm: service, imageService: ImageService(session: session), database: database, settings: settings)
            var completed = false
            do {
                for try await event in analyzer.analyzeChapter(chapter, book: book) {
                    if case .complete = event { completed = true }
                }
            } catch {
                XCTFail("\(provider.rawValue) analysis failed before atomic persistence: \(error)")
                throw error
            }
            XCTAssertTrue(completed, provider.rawValue)
            XCTAssertEqual(try database.fetchAnnotations(for: chapter).count, 1, provider.rawValue)
            XCTAssertEqual(try database.fetchChapters(for: book).first?.summary, "Gravity curves spacetime.", provider.rawValue)
            XCTAssertEqual(try database.fetchLLMCallUsage().count, 1, provider.rawValue)
        }
    }

    func testGeminiDisconnectAfterObservedStopKeepsCompletedAnswerUsageAndNativeState() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let payload = "data: "
            + #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Answer","thoughtSignature":"opaque"}]}}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20}}"#
            + "\n\n"
        ProviderProtocolURLProtocol.setHandler { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream", "X-Fixture-Open": "1"])!, Data(payload.utf8))
        }
        let service = LLMService(session: session)
        var settings = UserSettings()
        settings.llmProvider = .google
        settings.llmModel = SupportedModels.Google.gemini38Flash
        settings.googleAPIKey = "fixture-key"
        var saved: LLMConversationState?
        var text = ""
        var usages: [LLMService.TokenUsage] = []
        for try await chunk in service.chatStreaming(message: "Question", contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings, onProviderState: { saved = $0 }) {
            switch chunk {
            case .content(let delta):
                text += delta
                // The STOP-bearing event is now observed by the actual consumer,
                // before the fixture injects its transport error.
                XCTAssertTrue(ProviderProtocolURLProtocol.disconnectPending())
            case .usage(let usage): usages.append(usage)
            case .thinking: break
            }
        }
        XCTAssertEqual(text, "Answer")
        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages.first?.total, 120)
        let native = try XCTUnwrap(saved?.items(for: .google, model: settings.llmModel))
        XCTAssertEqual(native.first?["thoughtSignature"] as? String, "opaque")
    }

    func testGeminiExplicitStreamErrorAfterStopStillRejectsCompletionAndNativeState() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let payload = """
        data: {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Answer"}]}}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20}}

        data: {"error":{"message":"Explicit provider failure"}}

        """
        ProviderProtocolURLProtocol.setHandler { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(payload.utf8))
        }
        let service = LLMService(session: session)
        var settings = UserSettings()
        settings.llmProvider = .google
        settings.llmModel = SupportedModels.Google.gemini38Flash
        settings.googleAPIKey = "fixture-key"
        var saved: LLMConversationState?
        var usageEvents = 0
        do {
            for try await chunk in service.chatStreaming(message: "Question", contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings, onProviderState: { saved = $0 }) {
                if case .usage = chunk { usageEvents += 1 }
            }
            XCTFail("An explicit API error is not a harmless postcompletion socket close")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Explicit provider failure"))
        }
        XCTAssertNil(saved)
        XCTAssertEqual(usageEvents, 1)
    }

    func testClaudePausedNativeResponsesPreserveAssistantMessageBoundariesOnFollowup() throws {
        let model = SupportedModels.Anthropic.opus55
        var paused = LLMStreamAccumulator(provider: .anthropic)
        try paused.consumeResponse(["stop_reason": "pause_turn", "content": [["type": "redacted_thinking", "data": "signed-prefix-A"], ["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": ["query": "evidence"]]]])
        var completed = LLMStreamAccumulator(provider: .anthropic)
        try completed.consumeResponse(["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "Summary", "signature": "signed-prefix-B"], ["type": "text", "text": "Answer"]]])
        let pausedItems = try XCTUnwrap(paused.conversationState(model: model).items(for: .anthropic, model: model))
        let completedItems = try XCTUnwrap(completed.conversationState(model: model).items(for: .anthropic, model: model))
        let items = pausedItems + completedItems
        XCTAssertEqual(items.count, 2)
        let state = LLMConversationState(provider: .anthropic, model: model, payload: try JSONSerialization.data(withJSONObject: items))
        var prompt = LLMRequestPrompt(text: "Stable chapter context")
        prompt.conversation = [.init(role: .user, content: "Original question"), .init(role: .assistant, content: "Answer", providerState: state), .init(role: .user, content: "Followup")]
        let value = try body(request(AnthropicProvider(), model: model, prompt: prompt, search: true))
        let messages = try XCTUnwrap(value["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(try json(messages[1]), try json(pausedItems[0]))
        XCTAssertEqual(try json(messages[2]), try json(completedItems[0]))
        XCTAssertEqual(messages[3]["role"] as? String, "user")
    }

    func testGeminiDocumentedRESTSchemaRetainsThinkingAndSearch() throws {
        for model in [SupportedModels.Google.gemini38Flash, SupportedModels.Google.gemini4Argon, SupportedModels.Google.gemini31ProPreview] {
            let value = try body(request(GeminiProvider(), model: model, schema: SchemaLibrary.summaryOnly, search: true))
            let config = try XCTUnwrap(value["generationConfig"] as? [String: Any])
            let text = try XCTUnwrap((config["responseFormat"] as? [String: Any])?["text"] as? [String: Any])
            XCTAssertEqual(text["mimeType"] as? String, "APPLICATION_JSON")
            XCTAssertEqual(try json(try XCTUnwrap(text["schema"] as? [String: Any])), try json(SchemaLibrary.summaryOnly.schema))
            XCTAssertNotNil(config["thinkingConfig"])
            XCTAssertNotNil((value["tools"] as? [[String: Any]])?.first?["google_search"])
            XCTAssertNil(config["responseMimeType"])
            XCTAssertNil(config["responseJsonSchema"])
        }
    }

    func testOpenAIRefusalDrainsToUsageButNeverBecomesSuccessfulText() throws {
        let provider = OpenAIProvider()
        var emitted = ""
        try provider.handleStreamEvent(["type": "response.refusal.delta", "delta": "Cannot answer"]) { emitted += $0.text }
        let response: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "Cannot answer"]]]], "usage": ["input_tokens": 100, "output_tokens": 10]]
        XCTAssertEqual(provider.observedUsage(fromStreamEvent: ["type": "response.completed", "response": response])?.total, 110)
        XCTAssertThrowsError(try provider.handleStreamEvent(["type": "response.completed", "response": response], emit: { _ in }))
        XCTAssertTrue(emitted.isEmpty)
    }

    func testClaudeStrictSubmissionOnlyAcceptsItsDeclaredFinalObject() throws {
        let provider = AnthropicProvider(structuredOutputTool: true)
        let submission: [String: Any] = ["type": "tool_use", "id": "submit_1", "name": AnthropicProvider.structuredOutputToolName, "input": ["summary": "Continuity"]]
        let response: [String: Any] = ["stop_reason": "tool_use", "content": [["type": "text", "text": "Research prose"], submission], "usage": ["input_tokens": 100, "output_tokens": 30]]
        let (text, usage) = try provider.parseResponseText(from: json(response))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String], ["summary": "Continuity"])
        XCTAssertEqual(usage?.total, 130)
        XCTAssertThrowsError(try AnthropicProvider().parseResponseText(from: json(response)))
        for content in [
            [["type": "text", "text": #"{"summary":"Not submitted"}"#]],
            [submission, submission],
            [["type": "tool_use", "name": "undeclared_tool", "input": ["summary": "No"]]],
            [["type": "tool_use", "name": AnthropicProvider.structuredOutputToolName, "input": "Not an object"]]
        ] {
            XCTAssertThrowsError(try provider.parseResponseText(from: json(["stop_reason": "tool_use", "content": content])))
        }
        XCTAssertThrowsError(try provider.parseResponseText(from: json(["stop_reason": "end_turn", "content": [submission]])))
        var state = LLMStreamAccumulator(provider: .anthropic, structuredOutputTool: true)
        try state.consumeResponse(response)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(state.visibleText.utf8)) as? [String: String], ["summary": "Continuity"])
    }

    func testClaudeSubmissionAccumulatorHandlesJSONFragmentsWithoutExposingResearchAsJSON() throws {
        var state = LLMStreamAccumulator(provider: .anthropic, structuredOutputTool: true)
        try state.consume(["type": "message_start", "message": ["content": []]])
        try state.consume(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "Research only"]])
        try state.consume(["type": "content_block_stop", "index": 0])
        XCTAssertTrue(state.visibleText.isEmpty)
        try state.consume(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "submit_1", "name": AnthropicProvider.structuredOutputToolName, "input": [:]]])
        try state.consume(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": #"{"summary":"Con"#]])
        try state.consume(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": #"tinuity"}"#]])
        try state.consume(["type": "content_block_stop", "index": 1])
        try state.consume(["type": "message_delta", "delta": ["stop_reason": "tool_use"]])
        try state.consume(["type": "message_stop"])
        try state.finish()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(state.visibleText.utf8)) as? [String: String], ["summary": "Continuity"])
        XCTAssertFalse(state.needsContinuation)
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.Anthropic.opus55).items(for: .anthropic, model: SupportedModels.Anthropic.opus55))
        XCTAssertEqual(native.count, 1)
        let blocks = try XCTUnwrap(native.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks.contains { $0["type"] as? String == "tool_result" })
    }

    func testAstraRetainsSearchStructuredOutputAndReasoningTogether() throws {
        for level in ReasoningLevel.allCases {
            let value = try body(request(OpenAIProvider(), model: SupportedModels.OpenAI.gpt6Astra, reasoning: level, schema: SchemaLibrary.summaryOnly, search: true))
            XCTAssertEqual((value["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
            XCTAssertEqual(((value["text"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String, "json_schema")
            XCTAssertTrue(["low", "medium", "high", "xhigh", "max"].contains((value["reasoning"] as? [String: Any])?["effort"] as? String ?? ""))
            XCTAssertNil(value["temperature"])
        }
    }

    func testOpenAIStableCachePrefixHasExactBoundaryWithoutCachingChangingSuffix() throws {
        let prompt = LLMRequestPrompt(cachePrefix: "Stable chapter\n", cacheSuffix: "Changing task")
        for model in [SupportedModels.OpenAI.gpt61Sol, SupportedModels.OpenAI.gpt6Astra] {
            let value = try body(request(OpenAIProvider(), model: model, prompt: prompt))
            let parts = try XCTUnwrap((value["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
            XCTAssertEqual((value["prompt_cache_options"] as? [String: Any])?["mode"] as? String, "explicit")
            XCTAssertEqual(parts.compactMap { $0["text"] as? String }.joined(), prompt.text)
            XCTAssertEqual((parts.first?["prompt_cache_breakpoint"] as? [String: Any])?["mode"] as? String, "explicit")
            XCTAssertNil(parts.last?["prompt_cache_breakpoint"])
        }
        let legacy = try body(request(OpenAIProvider(), model: SupportedModels.OpenAI.gpt54, prompt: prompt))
        let parts = try XCTUnwrap((legacy["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertNil(parts.first?["prompt_cache_breakpoint"])
    }

    func testOpenAINativeReasoningNeverCrossesAuthenticationBoundaries() throws {
        let model = SupportedModels.OpenAI.gpt61Sol
        let original = OpenAIProvider(apiKey: "original-fixture-key")
        let same = OpenAIProvider(apiKey: "original-fixture-key")
        let rotated = OpenAIProvider(apiKey: "new-fixture-key")
        let subscription = OpenAIProvider(subscriptionCredential: .init(accessToken: "fixture", accountID: "account-A", residency: "us"))
        let otherAccount = OpenAIProvider(subscriptionCredential: .init(accessToken: "fixture", accountID: "account-B", residency: "us"))
        XCTAssertEqual(original.conversationScope, same.conversationScope)
        XCTAssertNotEqual(original.conversationScope, rotated.conversationScope)
        XCTAssertNotEqual(subscription.conversationScope, otherAccount.conversationScope)
        XCTAssertFalse(original.conversationScope?.contains("original-fixture-key") ?? true)
        let state = LLMConversationState(provider: .openai, model: model, payload: try JSONSerialization.data(withJSONObject: [["type": "reasoning", "encrypted_content": "account-bound"]]), scope: original.conversationScope)
        var prompt = LLMRequestPrompt(text: "Context")
        prompt.conversation = [.init(role: .user, content: "First"), .init(role: .assistant, content: "Visible", providerState: state), .init(role: .user, content: "Next")]
        for provider in [rotated, subscription, otherAccount, OpenAIProvider()] {
            let input = try XCTUnwrap(try body(request(provider, model: model, prompt: prompt))["input"] as? [[String: Any]])
            XCTAssertFalse(input.contains { $0["encrypted_content"] != nil })
            XCTAssertEqual(input[1]["content"] as? String, "Visible")
        }
    }

    func testGeminiServerToolPromptUsageMatchesProviderTotal() throws {
        let response: [String: Any] = [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["thought": true, "text": "Summary"], ["text": "Answer"]]]]],
            "usageMetadata": ["promptTokenCount": 100, "cachedContentTokenCount": 60, "toolUsePromptTokenCount": 30, "candidatesTokenCount": 20, "thoughtsTokenCount": 10, "totalTokenCount": 160]
        ]
        let (text, usage) = try GeminiProvider().parseResponseText(from: json(response))
        XCTAssertEqual(text, "Answer")
        XCTAssertEqual(usage?.input, 130)
        XCTAssertEqual(usage?.cached, 60)
        XCTAssertEqual(usage?.visibleOutput, 20)
        XCTAssertEqual(usage?.reasoning, 10)
        XCTAssertEqual(usage?.total, 160)
    }

    func testClaudeReasoningBreakdownAndMissingCacheReportingRemainAccurate() throws {
        let response: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "text", "text": "Answer"]], "usage": ["input_tokens": 100, "output_tokens": 40, "output_tokens_details": ["thinking_tokens": 30]]]
        let usage = try XCTUnwrap(AnthropicProvider().parseResponseText(from: json(response)).1)
        XCTAssertEqual(usage.visibleOutput, 10)
        XCTAssertEqual(usage.reasoning, 30)
        XCTAssertEqual(usage.total, 140)
        XCTAssertNil(usage.cached)
        XCTAssertNil(usage.cacheWrite)
        let explicit = AnthropicProvider().usage(fromResponse: ["usage": ["input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 2]])
        XCTAssertEqual(explicit?.cached, 0)
        XCTAssertEqual(explicit?.cacheWrite, 0)
    }

    func testClaudeThinkingModesRemainCompatibleWithJSONWithoutForcedTools() throws {
        let adaptive = try body(request(AnthropicProvider(), model: SupportedModels.Anthropic.opus55, schema: SchemaLibrary.summaryOnly))
        XCTAssertEqual((adaptive["thinking"] as? [String: Any])?["display"] as? String, "summarized")
        XCTAssertNil(adaptive["tool_choice"])
        let budget = try body(request(AnthropicProvider(), model: SupportedModels.Anthropic.sonnet45, schema: SchemaLibrary.summaryOnly))
        let thinking = try XCTUnwrap(budget["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertGreaterThanOrEqual(thinking["budget_tokens"] as? Int ?? 0, 1024)
        XCTAssertLessThan(thinking["budget_tokens"] as? Int ?? 0, budget["max_tokens"] as? Int ?? 0)
        XCTAssertNotNil((budget["output_config"] as? [String: Any])?["format"])
        XCTAssertNil(budget["tool_choice"])
    }

    func testFailedServerSearchCannotBecomeSuccessfulUnverifiedAnswer() throws {
        let openAI: [String: Any] = ["status": "completed", "output": [["type": "web_search_call", "status": "failed"], ["type": "message", "content": [["type": "output_text", "text": "Unverified"]]]], "usage": ["input_tokens": 10, "output_tokens": 5]]
        XCTAssertThrowsError(try OpenAIProvider().parseResponseText(from: json(openAI)))
        XCTAssertEqual(OpenAIProvider().usage(fromResponse: openAI)?.total, 15)
        XCTAssertThrowsError(try OpenAIProvider().handleStreamEvent(["type": "response.completed", "response": openAI], emit: { _ in }))
        let claude: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "web_search_tool_result", "content": ["type": "web_search_tool_result_error", "error_code": "unavailable"]], ["type": "text", "text": "Unverified"]]]
        XCTAssertThrowsError(try AnthropicProvider().parseResponseText(from: json(claude)))
        var stream = LLMStreamAccumulator(provider: .anthropic)
        try stream.consume(["type": "message_start", "message": ["content": []]])
        try stream.consume(["type": "content_block_start", "index": 0, "content_block": ["type": "web_search_tool_result", "content": ["type": "web_search_tool_result_error", "error_code": "unavailable"]]])
        try stream.consume(["type": "content_block_stop", "index": 0])
        try stream.consume(["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        XCTAssertThrowsError(try stream.consume(["type": "message_stop"]))
    }

    func testCompleteJSONUsesSameNativePauseLifecycleAndPreservesUsage() throws {
        var state = LLMStreamAccumulator(provider: .anthropic)
        try state.consumeResponse(["stop_reason": "pause_turn", "content": [["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": ["query": "evidence"]]], "usage": ["input_tokens": 100, "output_tokens": 8]])
        XCTAssertTrue(state.needsContinuation)
        XCTAssertEqual(state.visibleText, "")
        XCTAssertEqual(AnthropicProvider().usage(fromResponse: state.response)?.total, 108)
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.Anthropic.opus55).items(for: .anthropic, model: SupportedModels.Anthropic.opus55))
        XCTAssertEqual((native.first?["content"] as? [[String: Any]])?.first?["id"] as? String, "srv_1")
    }

    func testClaudeAccumulatedUsageIncludesFinalReasoningAndCitationDeltas() throws {
        var state = LLMStreamAccumulator(provider: .anthropic)
        let citation: [String: Any] = ["type": "web_search_result_location", "url": "https://example.org/source", "title": "Primary source", "encrypted_index": "opaque"]
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["content": [], "usage": ["input_tokens": 100, "cache_read_input_tokens": 60, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "Answer"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "citations_delta", "citation": citation]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 40, "output_tokens_details": ["thinking_tokens": 30]]],
            ["type": "message_stop"]
        ]
        for event in events { try state.consume(event) }
        let usage = try XCTUnwrap(AnthropicProvider().parseResponseText(from: json(state.response)).1)
        XCTAssertEqual(usage.input, 160)
        XCTAssertEqual(usage.cached, 60)
        XCTAssertEqual(usage.visibleOutput, 10)
        XCTAssertEqual(usage.reasoning, 30)
        XCTAssertEqual(usage.total, 200)
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.Anthropic.opus55).items(for: .anthropic, model: SupportedModels.Anthropic.opus55))
        let blocks = try XCTUnwrap(native.first?["content"] as? [[String: Any]])
        XCTAssertEqual((blocks.first?["citations"] as? [[String: Any]])?.first?["encrypted_index"] as? String, "opaque")
    }

    func testActualGeminiStreamReplaysFragmentedTextAndSignatureOnlyPartUnmodified() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let service = LLMService(session: session)
        let requests = ProviderRequestLog()
        let payloads: [[String: Any]] = [
            ["candidates": [["content": ["parts": [["thought": true, "text": "Display summary"]]]]]],
            ["candidates": [["content": ["parts": [["text": "An"]]]]]],
            ["candidates": [["content": ["parts": [["text": "swer"]]]]]],
            ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "", "thoughtSignature": "opaque-signature"]]]]]],
            ["usageMetadata": ["promptTokenCount": 100, "cachedContentTokenCount": 60, "toolUsePromptTokenCount": 30, "candidatesTokenCount": 20, "thoughtsTokenCount": 10, "totalTokenCount": 160]]
        ]
        let payload = try payloads.map { "data: \(String(decoding: try json($0), as: UTF8.self))\n\n" }.joined()
        ProviderProtocolURLProtocol.setHandler { request in
            requests.append(try providerRequestJSON(request))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(payload.utf8))
        }
        var settings = UserSettings()
        settings.llmProvider = .google
        settings.llmModel = SupportedModels.Google.gemini38Flash
        settings.googleAPIKey = "fixture-key"
        var saved: LLMConversationState?
        var text = ""
        var usage: [LLMService.TokenUsage] = []
        for try await chunk in service.chatStreaming(message: "Question", contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings, onProviderState: { saved = $0 }) {
            if case .content(let delta) = chunk { text += delta }
            if case .usage(let value) = chunk { usage.append(value) }
        }
        XCTAssertEqual(text, "Answer")
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.total, 160)
        let state = try XCTUnwrap(saved)
        let native = try XCTUnwrap(state.items(for: .google, model: settings.llmModel))
        XCTAssertEqual(native.compactMap { $0["text"] as? String }, ["Display summary", "An", "swer", ""])
        XCTAssertEqual(native.last?["thoughtSignature"] as? String, "opaque-signature")
        let history: [LLMService.ChatTurn] = [.init(role: .user, content: "Question"), .init(role: .assistant, content: "Answer", providerState: state)]
        for try await _ in service.chatStreaming(message: "Follow up", previousTurns: history, contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings) {}
        let calls = requests.snapshot()
        XCTAssertEqual(calls.count, 2)
        let contents = try XCTUnwrap(calls.last?["contents"] as? [[String: Any]])
        let replay = try XCTUnwrap(contents.first { $0["role"] as? String == "model" }?["parts"] as? [[String: Any]])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: replay, options: .sortedKeys), try JSONSerialization.data(withJSONObject: native, options: .sortedKeys))
    }

    func testActualCompleteJSONFallbackPublishesTextUsageAndNativeStateForEveryProvider() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let service = LLMService(session: session)
        let cases: [(LLMProvider, String, [String: Any])] = [
            (.openai, SupportedModels.OpenAI.gpt6Astra, ["status": "completed", "output": [["type": "reasoning", "encrypted_content": "opaque"], ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Answer"]]]], "usage": ["input_tokens": 100, "output_tokens": 30, "output_tokens_details": ["reasoning_tokens": 10]]]),
            (.anthropic, SupportedModels.Anthropic.opus55, ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "Summary", "signature": "opaque"], ["type": "text", "text": "Answer"]], "usage": ["input_tokens": 100, "output_tokens": 30, "output_tokens_details": ["thinking_tokens": 10]]]),
            (.google, SupportedModels.Google.gemini38Flash, ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "Answer", "thoughtSignature": "opaque"]]]]], "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20, "thoughtsTokenCount": 10]])
        ]
        for (provider, model, response) in cases {
            let payload = try json(response)
            ProviderProtocolURLProtocol.setHandler { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, payload)
            }
            var settings = UserSettings()
            settings.llmProvider = provider
            settings.llmModel = model
            settings.openAIAPIKey = "fixture-key"
            settings.anthropicAPIKey = "fixture-key"
            settings.googleAPIKey = "fixture-key"
            var state: LLMConversationState?
            var text = ""
            var usages: [LLMService.TokenUsage] = []
            for try await chunk in service.chatStreaming(message: "Question", contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings, onProviderState: { state = $0 }) {
                if case .content(let delta) = chunk { text += delta }
                if case .usage(let usage) = chunk { usages.append(usage) }
            }
            XCTAssertEqual(text, "Answer", provider.rawValue)
            XCTAssertEqual(usages.count, 1, provider.rawValue)
            XCTAssertEqual(usages.first?.total, 130, provider.rawValue)
            XCTAssertNotNil(try state?.items(for: provider, model: model), provider.rawValue)
            if provider == .openai { XCTAssertEqual(state?.scope, OpenAIProvider(apiKey: "fixture-key").conversationScope) }
        }
    }

    func testOpenAIStatelessConversationPreservesEncryptedItemsAndRoles() throws {
        let model = SupportedModels.OpenAI.gpt61Sol
        let provider = OpenAIProvider(apiKey: "fixture-key")
        let items: [[String: Any]] = [
            ["type": "reasoning", "id": "rs_1", "encrypted_content": "opaque-ciphertext", "summary": [["type": "summary_text", "text": "Only a display summary"]]],
            ["type": "message", "id": "msg_1", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "Earlier answer", "annotations": []]]]
        ]
        let state = LLMConversationState(provider: .openai, model: model, payload: try JSONSerialization.data(withJSONObject: items), scope: provider.conversationScope)
        var prompt = LLMRequestPrompt(text: "Chapter and spoiler boundary")
        prompt.conversation = [.init(role: .user, content: "Earlier question"), .init(role: .assistant, content: "Earlier answer", providerState: state), .init(role: .user, content: "Go deeper")]
        let value = try body(request(provider, model: model, prompt: prompt))
        let input = try XCTUnwrap(value["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque-ciphertext")
        XCTAssertEqual(input[2]["role"] as? String, "assistant")
        XCTAssertEqual(input[3]["content"] as? String, "Go deeper")
        XCTAssertEqual(value["store"] as? Bool, false)
        XCTAssertEqual(value["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertNil(value["temperature"])
        XCTAssertNil(value["previous_response_id"])
    }

    func testNativeStateNeverCrossesProviderOrModelBoundary() throws {
        let state = LLMConversationState(provider: .openai, model: SupportedModels.OpenAI.gpt61Sol, payload: Data("not JSON".utf8))
        XCTAssertNil(try state.items(for: .google, model: SupportedModels.OpenAI.gpt61Sol))
        XCTAssertNil(try state.items(for: .openai, model: SupportedModels.OpenAI.gpt6Astra))
        XCTAssertThrowsError(try state.items(for: .openai, model: SupportedModels.OpenAI.gpt61Sol))
        var prompt = LLMRequestPrompt(text: "Context")
        prompt.conversation = [.init(role: .user, content: "Question"), .init(role: .assistant, content: "Visible answer", providerState: state), .init(role: .user, content: "Next")]
        let value = try body(request(GeminiProvider(), model: SupportedModels.Google.gemini38Flash, prompt: prompt))
        let contents = try XCTUnwrap(value["contents"] as? [[String: Any]])
        XCTAssertEqual(contents[1]["role"] as? String, "model")
        XCTAssertEqual((contents[1]["parts"] as? [[String: Any]])?.first?["text"] as? String, "Visible answer")
    }

    func testCodexSubscriptionUsesVerifiedEndpointHeadersAndSSEBody() throws {
        let credential = OpenAISubscriptionCredential(accessToken: "fixture-oauth-token", accountID: "fixture-account", residency: "eu")
        let provider = OpenAIProvider(subscriptionCredential: credential, sessionID: "fixture-session")
        let req = try request(provider, model: SupportedModels.OpenAI.gpt61Sol, schema: SchemaLibrary.summaryOnly)
        let value = try body(req)
        XCTAssertEqual(req.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-oauth-token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture-account")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-openai-internal-codex-residency"), "eu")
        XCTAssertEqual(req.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(req.value(forHTTPHeaderField: "session-id"), "fixture-session")
        XCTAssertEqual(value["store"] as? Bool, false)
        XCTAssertEqual(value["stream"] as? Bool, true)
        XCTAssertNil(value["max_output_tokens"])
        XCTAssertNil(value["temperature"])
        XCTAssertNil(value["previous_response_id"])
        XCTAssertNotNil(value["text"])
    }

    func testModernReasoningControlsAreCatalogBound() throws {
        let openAI = try body(request(OpenAIProvider(), model: SupportedModels.OpenAI.gpt61Sol, reasoning: .off))
        XCTAssertEqual((openAI["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(openAI["temperature"])
        let claude = try body(request(AnthropicProvider(), model: SupportedModels.Anthropic.opus55, reasoning: .off, schema: SchemaLibrary.summaryOnly))
        XCTAssertEqual((claude["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertNotNil((claude["output_config"] as? [String: Any])?["format"])
        XCTAssertNil(claude["output_format"])
        XCTAssertNil(claude["temperature"])
        let geminiRequest = try request(GeminiProvider(), model: SupportedModels.Google.gemini38Flash, reasoning: .minimal)
        let gemini = try body(geminiRequest)
        let generation = try XCTUnwrap(gemini["generationConfig"] as? [String: Any])
        XCTAssertEqual((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "low")
        XCTAssertFalse(geminiRequest.url!.absoluteString.contains("fixture-key"))
        XCTAssertEqual(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
    }

    func testSubscriptionUtilitySelectionNeverFallsBackToPaidAPIKeys() {
        var settings = UserSettings()
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.gpt61Sol
        settings.openAIAuthenticationMode = .chatGPTSubscription
        settings.openAIAPIKey = "unused-paid-key"
        settings.googleAPIKey = "unused-google-key"
        settings.anthropicAPIKey = "unused-anthropic-key"
        let selection = LLMService().classificationModelSelection(settings: settings)
        XCTAssertEqual(selection.0, .openai)
        XCTAssertEqual(selection.1, SupportedModels.utilityModel(for: .openai))
        XCTAssertTrue(selection.2.isEmpty)
    }

    func testToggleableAdaptiveThinkingCanBeDisabledWithoutSampling() throws {
        let value = try body(request(AnthropicProvider(), model: SupportedModels.Anthropic.haiku55, reasoning: .off))
        XCTAssertEqual((value["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(value["temperature"])
        XCTAssertThrowsError(try request(AnthropicProvider(), model: SupportedModels.Anthropic.opus55, schema: SchemaLibrary.summaryOnly, search: true))
    }

    func testUnregisteredModelDoesNotReceiveGuessedReasoningParameters() throws {
        let value = try body(request(OpenAIProvider(), model: "custom-reasoner-pro-flash"))
        XCTAssertNil(value["reasoning"])
        XCTAssertNil(value["temperature"])
        XCTAssertThrowsError(try request(OpenAIProvider(), model: "custom-reasoner-pro-flash", search: true))
    }

    func testAllOpenAIMessagesAreCollectedNotOnlyFirstMessage() throws {
        let response: [String: Any] = ["status": "completed", "output": [
            ["type": "message", "content": [["type": "output_text", "text": "First"]]],
            ["type": "message", "content": [["type": "output_text", "text": "Second"]]]
        ]]
        XCTAssertEqual(try OpenAIProvider().parseResponseText(from: json(response)).0, "FirstSecond")
    }

    func testNonStreamingIncompleteAndRefusedResponsesRejectVisiblePartialText() throws {
        let output: [[String: Any]] = [["type": "message", "content": [["type": "output_text", "text": "Partial answer"]]]]
        for status in ["incomplete", "failed", "cancelled", "in_progress"] {
            XCTAssertThrowsError(try OpenAIProvider().parseResponseText(from: json(["status": status, "output": output])))
        }
        XCTAssertThrowsError(try OpenAIProvider().parseResponseText(from: json(["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "Cannot answer"]]]]])))
        for reason in ["MAX_TOKENS", "SAFETY", "RECITATION", "MALFORMED_FUNCTION_CALL"] {
            XCTAssertThrowsError(try GeminiProvider().parseResponseText(from: json(["candidates": [["finishReason": reason, "content": ["parts": [["text": "Partial answer"]]]]]])))
        }
        for reason in ["max_tokens", "refusal", "tool_use", "pause_turn"] {
            XCTAssertThrowsError(try AnthropicProvider().parseResponseText(from: json(["stop_reason": reason, "content": [["type": "text", "text": "Partial answer"]]])))
        }
    }

    func testOpenAICacheWritesRemainDistinctFromCacheReads() throws {
        let data = try json([
            "status": "completed",
            "output": [["type": "message", "content": [["type": "output_text", "text": "Answer"]]]],
            "usage": ["input_tokens": 1000, "output_tokens": 20, "input_tokens_details": ["cached_tokens": 400, "cache_write_tokens": 300], "output_tokens_details": ["reasoning_tokens": 5]]
        ])
        let usage = try XCTUnwrap(OpenAIProvider().parseResponseText(from: data).1)
        XCTAssertEqual(usage.input, 1000)
        XCTAssertEqual(usage.cached, 400)
        XCTAssertEqual(usage.cacheWrite, 300)
        XCTAssertEqual(usage.visibleOutput, 15)
        XCTAssertEqual(usage.reasoning, 5)
        XCTAssertEqual(usage.total, 1020)
    }

    func testCompleteJSONFallbackStillRequiresOfficialCompletionMetadata() throws {
        XCTAssertThrowsError(try OpenAIProvider().parseResponseText(from: json(["output": [["type": "message", "content": [["type": "output_text", "text": "Partial"]]]]])))
        XCTAssertThrowsError(try GeminiProvider().parseResponseText(from: json(["candidates": [["content": ["parts": [["text": "Partial"]]]]]])))
        XCTAssertThrowsError(try AnthropicProvider().parseResponseText(from: json(["content": [["type": "text", "text": "Partial"]]])))
    }

    func testSSEHandlesCRLFMultilineUnicodeAndUnterminatedLastEvent() throws {
        var lines = SSELineParser()
        var events = SSEEventParser()
        var payloads: [String] = []
        let text = ": heartbeat\r\ndata: {\r\ndata: \"text\":\"星\"}\r\n\r\ndata: [DONE]"
        for byte in text.utf8 {
            try lines.append(byte: byte) { line in try events.append(line: line) { payloads.append($0) } }
        }
        try lines.finalize { line in try events.append(line: line) { payloads.append($0) } }
        try events.finalize { payloads.append($0) }
        XCTAssertEqual(payloads, ["{\n\"text\":\"星\"}", "[DONE]"])
        XCTAssertNil(ssePayload(from: " data: not an SSE field"))
    }

    func testStreamEOFRequiresProviderTerminalEvent() throws {
        var openAI = LLMStreamAccumulator(provider: .openai)
        try openAI.consume(["type": "response.output_text.delta", "delta": "Partial"])
        XCTAssertThrowsError(try openAI.finish())
        var gemini = LLMStreamAccumulator(provider: .google)
        try gemini.consume(["candidates": [["content": ["parts": [["text": "Partial"]]]]]])
        XCTAssertThrowsError(try gemini.finish())
        var claude = LLMStreamAccumulator(provider: .anthropic)
        try claude.consume(["type": "message_start", "message": ["content": []]])
        XCTAssertThrowsError(try claude.finish())
    }

    func testClaudeAccumulatorPreservesSignedAndRedactedThinkingAndServerResults() throws {
        var state = LLMStreamAccumulator(provider: .anthropic)
        try state.consume(["type": "message_start", "message": ["role": "assistant", "content": []]])
        try state.consume(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]])
        try state.consume(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Native thinking"]])
        try state.consume(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "signature-A"]])
        try state.consume(["type": "content_block_stop", "index": 0])
        try state.consume(["type": "content_block_start", "index": 1, "content_block": ["type": "redacted_thinking", "data": "opaque-redacted"]])
        try state.consume(["type": "content_block_stop", "index": 1])
        try state.consume(["type": "content_block_start", "index": 2, "content_block": ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [["type": "web_search_result", "url": "https://example.org/source", "encrypted_content": "opaque-result"]]]])
        try state.consume(["type": "content_block_stop", "index": 2])
        try state.consume(["type": "message_delta", "delta": ["stop_reason": "pause_turn"]])
        try state.consume(["type": "message_stop"])
        XCTAssertTrue(state.needsContinuation)
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.Anthropic.opus55).items(for: .anthropic, model: SupportedModels.Anthropic.opus55))
        let blocks = try XCTUnwrap(native.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["signature"] as? String, "signature-A")
        XCTAssertEqual(blocks[1]["data"] as? String, "opaque-redacted")
        XCTAssertEqual(blocks[2]["tool_use_id"] as? String, "srv_1")
    }

    func testGeminiSignatureOnlyFinalPartSurvivesReplay() throws {
        var state = LLMStreamAccumulator(provider: .google)
        try state.consume(["candidates": [["content": ["parts": [["text": "Answer"]]]]]])
        try state.consume(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "", "thoughtSignature": "opaque-signature"]]]]]])
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.Google.gemini38Flash).items(for: .google, model: SupportedModels.Google.gemini38Flash))
        XCTAssertEqual(native.count, 2)
        XCTAssertEqual(native.last?["thoughtSignature"] as? String, "opaque-signature")
    }

    func testCodexDoneRequiresCompletedStatusAndPreservesOpaqueReasoning() throws {
        var state = LLMStreamAccumulator(provider: .openai)
        try state.consume(["type": "response.done", "response": ["status": "completed", "output": [["type": "reasoning", "encrypted_content": "opaque"]]]])
        try state.finish()
        let native = try XCTUnwrap(state.conversationState(model: SupportedModels.OpenAI.gpt61Sol).items(for: .openai, model: SupportedModels.OpenAI.gpt61Sol))
        XCTAssertEqual(native.first?["encrypted_content"] as? String, "opaque")
        var failed = LLMStreamAccumulator(provider: .openai)
        XCTAssertThrowsError(try failed.consume(["type": "response.done", "response": ["status": "incomplete"]]))
    }

    func testActualChatPathOnlyPublishesNativeStateAfterTerminalSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = LLMService(session: session)
        defer {
            session.invalidateAndCancel()
            ProviderProtocolURLProtocol.setHandler(nil)
        }
        var settings = UserSettings()
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.gpt61Sol
        settings.openAIAPIKey = "fixture-key"
        let successful = """
        data: {"type":"response.output_text.delta","delta":"Answer"}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}]}}

        """
        ProviderProtocolURLProtocol.setHandler { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(successful.utf8))
        }
        var saved: LLMConversationState?
        var text = ""
        for try await chunk in service.chatStreaming(message: "Question", contentWithBlocks: "[1] Text", rollingSummary: nil, settings: settings, onProviderState: { saved = $0 }) {
            if case .content(let delta) = chunk { text += delta }
        }
        XCTAssertEqual(text, "Answer")
        XCTAssertEqual(try saved?.items(for: .openai, model: settings.llmModel)?.first?["encrypted_content"] as? String, "opaque")
        saved = nil
        ProviderProtocolURLProtocol.setHandler { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n".utf8))
        }
        do {
            for try await _ in service.chatStreaming(message: "Question", contentWithBlocks: "[1] Text", rollingSummary: nil, settings: settings, onProviderState: { saved = $0 }) {}
            XCTFail("EOF must not turn a partial answer into success")
        } catch LLMService.LLMError.apiError {
            // The failed response must not publish replayable conversation state.
        } catch {
            XCTFail("Expected a provider completion failure, got \(error)")
        }
        XCTAssertNil(saved)
    }

    func testClaudeGroundedAnalysisUsesOneNativeTurnAndStrictFinalSubmission() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let service = LLMService(session: session)
        let requests = ProviderRequestLog()
        let response = try claudeSubmissionStream()
        ProviderProtocolURLProtocol.setHandler { request in
            requests.append(try providerRequestJSON(request))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(response.utf8))
        }
        var settings = UserSettings()
        settings.llmProvider = .anthropic
        settings.llmModel = SupportedModels.Anthropic.opus55
        settings.anthropicAPIKey = "fixture-key"
        settings.webSearchEnabled = true
        var result: LLMService.ChapterAnalysis?
        for try await event in service.analyzeChapterStreaming(contentWithBlocks: "[1] Passage", rollingSummary: nil, bookTitle: nil, author: nil, settings: settings) {
            if case .completed(let analysis) = event { result = analysis }
        }
        XCTAssertEqual(result?.summary, "Continuity")
        let calls = requests.snapshot()
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        let tools = try XCTUnwrap(call["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "web_search")
        let submission = try XCTUnwrap(tools.first { $0["name"] as? String == AnthropicProvider.structuredOutputToolName })
        XCTAssertEqual(submission["strict"] as? Bool, true)
        XCTAssertNotNil(submission["input_schema"])
        XCTAssertNil((call["output_config"] as? [String: Any])?["format"])
        XCTAssertEqual((call["tool_choice"] as? [String: Any])?["type"] as? String, "auto")
        XCTAssertEqual((call["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
    }

    func testClaudeSearchPauseContinuesWithNativeBlocksWithoutClientToolFabrication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let service = LLMService(session: session)
        let requests = ProviderRequestLog()
        let paused = [
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque-redacted"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"evidence"}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#,
            #"{"type":"message_stop"}"#
        ].map { "data: \($0)\n\n" }.joined()
        let final = try claudeSubmissionStream()
        ProviderProtocolURLProtocol.setHandler { request in
            let value = try providerRequestJSON(request)
            requests.append(value)
            let messages = value["messages"] as? [[String: Any]] ?? []
            let response = messages.count == 1 ? paused : final
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(response.utf8))
        }
        var settings = UserSettings()
        settings.llmProvider = .anthropic
        settings.llmModel = SupportedModels.Anthropic.opus55
        settings.anthropicAPIKey = "fixture-key"
        settings.webSearchEnabled = true
        _ = try await service.analyzeChapter(contentWithBlocks: "[1] Passage", rollingSummary: nil, bookTitle: nil, author: nil, settings: settings)
        let calls = requests.snapshot()
        XCTAssertEqual(calls.count, 2)
        guard calls.count == 2 else { return }
        XCTAssertEqual(try json(["tools": calls[0]["tools"] ?? []]), try json(["tools": calls[1]["tools"] ?? []]))
        XCTAssertEqual(try json(["system": calls[0]["system"] ?? NSNull()]), try json(["system": calls[1]["system"] ?? NSNull()]))
        let messages = try XCTUnwrap(calls[1]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "assistant")
        let blocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["data"] as? String, "opaque-redacted")
        XCTAssertEqual(blocks.last?["id"] as? String, "srv_1")
        XCTAssertFalse(blocks.contains { $0["type"] as? String == "tool_result" })
    }

    func testEmptyChapterSummaryIsNotAcceptedAsContinuity() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProtocolURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ProviderProtocolURLProtocol.setHandler(nil) }
        let service = LLMService(session: session)
        let payload = try json(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": #"{"summary":"  "}"#]]]]]])
        ProviderProtocolURLProtocol.setHandler { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, payload)
        }
        var settings = UserSettings()
        settings.googleAPIKey = "fixture-key"
        do {
            _ = try await service.generateSummary(contentWithBlocks: "[1] Passage", rollingSummary: nil, settings: settings)
            XCTFail("Blank continuity must not be persisted")
        } catch let error as ChapterAnalysisValidationError {
            XCTAssertEqual(error.localizedDescription, ChapterAnalysisValidationError.emptyField("chapter summary").localizedDescription)
        }
    }

    private func claudeSubmissionStream() throws -> String {
        let text = #"{"summary":"Continuity","annotations":[],"quizQuestions":[],"imageSuggestions":[]}"#
        let split = text.index(text.startIndex, offsetBy: text.count / 2)
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["role": "assistant", "content": []]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Research prose that must not corrupt the final JSON."]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "tool_submit", "name": AnthropicProvider.structuredOutputToolName, "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": String(text[..<split])]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": String(text[split...])]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
            ["type": "message_stop"]
        ]
        return try events.map { "data: \(String(decoding: try json($0), as: UTF8.self))\n\n" }.joined()
    }
}

func providerRequestJSON(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else {
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        data = body
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class ProviderProtocolURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var pending: ProviderProtocolURLProtocol?

    static func setHandler(_ value: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        handler = value
        pending = nil
        lock.unlock()
    }
    static func disconnectPending() -> Bool {
        let receiver = lock.withLock {
            let receiver = pending
            pending = nil
            return receiver
        }
        guard let receiver else { return false }
        receiver.client?.urlProtocol(receiver, didFailWithError: URLError(.networkConnectionLost))
        return true
    }


    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            let leavesConnectionOpen = response.value(forHTTPHeaderField: "X-Fixture-Open") == "1"
            if leavesConnectionOpen { Self.lock.withLock { Self.pending = self } }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            // OpenAI/Claude must finish from their terminal events with no EOF.
            // Gemini disconnect fixtures fail only after the consumer acknowledges STOP.
            if !leavesConnectionOpen { client?.urlProtocolDidFinishLoading(self) }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.lock.withLock {
            if Self.pending === self { Self.pending = nil }
        }
    }
}

final class ProviderRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Any]] = []

    func append(_ value: [String: Any]) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
