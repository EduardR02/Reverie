import XCTest
@testable import Reverie

final class LLMGoldenTests: XCTestCase {
    
    private func getFixtureData(name: String) throws -> Data {
        // Robust fixture path resolution for both Xcode and CLI
        let fileManager = FileManager.default
        let currentFileURL = URL(fileURLWithPath: #file)
        
        // Strategy 1: Check relative to #file (Project structure)
        let projectFixturesURL = currentFileURL
            .deletingLastPathComponent() // ReverieTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            
        if fileManager.fileExists(atPath: projectFixturesURL.path) {
            return try Data(contentsOf: projectFixturesURL)
        }
        
        // Strategy 2: Check via Bundle.module (SPM resources)
        if let bundleURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
            return try Data(contentsOf: bundleURL)
        }
        
        throw NSError(domain: "Test", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing fixture: \(name). Checked project path and bundle."])
    }

    @MainActor
    func testRealGeminiAnalysisParsing() throws {
        let data = try getFixtureData(name: "analysis_gemini_3_flash.json")
        let provider = GeminiProvider()
        
        let (text, usage) = try provider.parseResponseText(from: data)
        
        XCTAssertEqual(usage?.input, 2966)
        XCTAssertEqual(usage?.reasoning, 1033)
        XCTAssertEqual(usage?.visibleOutput, 1305)  // candidates only, reasoning tracked separately
        
        let decoder = JSONDecoder()
        let analysis = try decoder.decode(LLMService.ChapterAnalysis.self, from: text.data(using: .utf8)!)
        
        XCTAssertEqual(analysis.quizQuestions.count, 3)
        XCTAssertGreaterThan(analysis.annotations.count, 0)
        XCTAssertFalse(analysis.summary.isEmpty)
    }

    @MainActor
    func testRealGPT52AnalysisParsing() throws {
        let data = try getFixtureData(name: "analysis_gpt-5_2.json")
        let provider = OpenAIProvider()

        let (text, usage) = try provider.parseResponseText(from: data)

        // OpenAI: output_tokens (5702) INCLUDES reasoning_tokens (2834)
        // Normalized: output = 5702 - 2834 = 2868 (visible output only)
        XCTAssertEqual(usage?.input, 2965)
        XCTAssertEqual(usage?.visibleOutput, 2868)
        XCTAssertEqual(usage?.reasoning, 2834)
        XCTAssertEqual(usage?.cached, 0)

        let decoder = JSONDecoder()
        let analysis = try decoder.decode(LLMService.ChapterAnalysis.self, from: text.data(using: .utf8)!)

        XCTAssertGreaterThan(analysis.annotations.count, 0)
        XCTAssertFalse(analysis.summary.isEmpty)
    }

    @MainActor
    func testRealSonnet45AnalysisParsing() throws {
        let data = try getFixtureData(name: "analysis_sonnet-4_5.json")
        let provider = AnthropicProvider()

        let (text, usage) = try provider.parseResponseText(from: data)

        // Anthropic: input = input_tokens + cache_creation + cache_read
        XCTAssertEqual(usage?.input, 3753)
        XCTAssertEqual(usage?.visibleOutput, 15901)
        XCTAssertEqual(usage?.cached, 0)

        let decoder = JSONDecoder()
        let analysis = try decoder.decode(LLMService.ChapterAnalysis.self, from: text.data(using: .utf8)!)

        XCTAssertGreaterThan(analysis.annotations.count, 0)
        XCTAssertFalse(analysis.summary.isEmpty)
    }

    @MainActor
    func testRealGeminiClassificationParsing() throws {
        let data = try getFixtureData(name: "classification_gemini_3_flash.json")
        let provider = GeminiProvider()
        
        let (text, _) = try provider.parseResponseText(from: data)
        XCTAssertTrue(text.contains("classifications"))
        XCTAssertTrue(text.contains("garbage") || text.contains("content"))
    }

    @MainActor
    func testOpenAIUsageParsing() throws {
        let jsonString = """
        {
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "Hello"}]}],
            "usage": {
                "input_tokens": 100,
                "input_tokens_details": {"cached_tokens": 40},
                "output_tokens": 50,
                "output_tokens_details": {"reasoning_tokens": 10}
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let provider = OpenAIProvider()
        let (_, usage) = try provider.parseResponseText(from: data)

        // OpenAI: output_tokens (50) INCLUDES reasoning_tokens (10)
        // Normalized: output = 50 - 10 = 40 (visible output only)
        XCTAssertEqual(usage?.input, 100)
        XCTAssertEqual(usage?.visibleOutput, 40)
        XCTAssertEqual(usage?.cached, 40)
        XCTAssertEqual(usage?.reasoning, 10)
    }

    @MainActor
    func testAnthropicUsageParsing() throws {
        let jsonString = """
        {
            "content": [{"type": "text", "text": "Claude response"}],
            "usage": {
                "input_tokens": 411,
                "cache_creation_input_tokens": 100,
                "cache_read_input_tokens": 50,
                "output_tokens": 79
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let provider = AnthropicProvider()
        let (text, usage) = try provider.parseResponseText(from: data)

        // Anthropic: input_tokens (411) already INCLUDES cache_read (50)
        // cache_creation (100) is additional tokens written to cache
        // Total input = input_tokens + cache_creation = 411 + 100 = 511
        XCTAssertEqual(text, "Claude response")
        XCTAssertEqual(usage?.input, 511)
        XCTAssertEqual(usage?.visibleOutput, 79)
        XCTAssertEqual(usage?.cached, 50)
    }

    @MainActor
    func testAnnotationSourceBlockIdParsedCorrectly() throws {
        let data = try getFixtureData(name: "analysis_gemini_3_flash.json")
        let provider = GeminiProvider()

        let (text, _) = try provider.parseResponseText(from: data)

        let decoder = JSONDecoder()
        let analysis = try decoder.decode(LLMService.ChapterAnalysis.self, from: text.data(using: .utf8)!)

        XCTAssertGreaterThan(analysis.annotations.count, 0)

        for annotation in analysis.annotations {
            XCTAssertGreaterThan(annotation.sourceBlockId, 0, "sourceBlockId should be positive integer")
            XCTAssertFalse(annotation.content.isEmpty, "Annotation content should not be empty")
            XCTAssertFalse(annotation.title.isEmpty, "Annotation title should not be empty")
        }

        let blockIds = analysis.annotations.map { $0.sourceBlockId }
        XCTAssertEqual(Set(blockIds).count, blockIds.count, "All sourceBlockId values should be unique")
    }

    @MainActor
    func testAllGeminiAnnotationsHaveValidBlockIds() throws {
        let data = try getFixtureData(name: "analysis_gemini_3_flash.json")
        let provider = GeminiProvider()

        let (text, _) = try provider.parseResponseText(from: data)

        let decoder = JSONDecoder()
        let analysis = try decoder.decode(LLMService.ChapterAnalysis.self, from: text.data(using: .utf8)!)

        for annotation in analysis.annotations {
            XCTAssertGreaterThanOrEqual(annotation.sourceBlockId, 1, "Block ID should be >= 1")
        }
    }

    // MARK: - Streaming Token Counting Tests

    @MainActor
    func testGeminiStreamingOnlyYieldsUsageOnFinalChunk() async throws {
        let provider = GeminiProvider()

        // Simulate intermediate chunk (no finishReason) - should NOT yield usage
        let intermediateChunk: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": "Hello"]]]
                // No finishReason - this is an intermediate chunk
            ]],
            "usageMetadata": [
                "promptTokenCount": 100,
                "candidatesTokenCount": 10,
                "totalTokenCount": 110
            ]
        ]

        var usageCount = 0
        let intermediateStream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            do {
                try provider.handleStreamEvent(intermediateChunk, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        for try await chunk in intermediateStream {
            if case .usage = chunk {
                usageCount += 1
            }
        }
        XCTAssertEqual(usageCount, 0, "Intermediate chunk should NOT yield usage")

        // Simulate final chunk (has finishReason) - should yield usage
        let finalChunk: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": " World"]]],
                "finishReason": "STOP"  // This marks it as final
            ]],
            "usageMetadata": [
                "promptTokenCount": 100,
                "candidatesTokenCount": 50,
                "totalTokenCount": 150,
                "thoughtsTokenCount": 20
            ]
        ]

        var finalUsage: LLMService.TokenUsage?
        let finalStream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            do {
                try provider.handleStreamEvent(finalChunk, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        for try await chunk in finalStream {
            if case .usage(let usage) = chunk {
                finalUsage = usage
            }
        }

        XCTAssertNotNil(finalUsage, "Final chunk should yield usage")
        XCTAssertEqual(finalUsage?.input, 100)
        XCTAssertEqual(finalUsage?.visibleOutput, 50)
        XCTAssertEqual(finalUsage?.reasoning, 20)
    }

    @MainActor
    func testGeminiStreamingDoesNotDoubleCountTokens() async throws {
        // Verify that output doesn't include thoughts (they're tracked separately as reasoning)
        let provider = GeminiProvider()

        let chunk: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": "Response"]]],
                "finishReason": "STOP"
            ]],
            "usageMetadata": [
                "promptTokenCount": 1000,
                "candidatesTokenCount": 500,  // This is OUTPUT only
                "totalTokenCount": 1700,
                "thoughtsTokenCount": 200     // This is REASONING only
            ]
        ]

        var capturedUsage: LLMService.TokenUsage?
        let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            do {
                try provider.handleStreamEvent(chunk, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        for try await c in stream {
            if case .usage(let u) = c { capturedUsage = u }
        }

        // Verify no double-counting: visibleOutput should be candidates only, not candidates + thoughts
        XCTAssertEqual(capturedUsage?.visibleOutput, 500, "visibleOutput should be candidatesTokenCount only")
        XCTAssertEqual(capturedUsage?.reasoning, 200, "Reasoning should be thoughtsTokenCount")

        // Total should be input + visibleOutput + reasoning = 1000 + 500 + 200 = 1700
        let computedTotal = (capturedUsage?.input ?? 0) + (capturedUsage?.visibleOutput ?? 0) + (capturedUsage?.reasoning ?? 0)
        XCTAssertEqual(computedTotal, 1700, "Total should match: input + visibleOutput + reasoning")
    }

    // MARK: - Real Streaming Fixture Tests

    @MainActor
    func testRealGeminiStreamingFixture() async throws {
        // Load real streaming fixture (JSONL format - one JSON per line)
        let data = try getFixtureData(name: "analysis_gemini_3_flash_stream.jsonl")
        let content = String(data: data, encoding: .utf8)!
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 48, "Fixture should have 48 streaming chunks")

        let provider = GeminiProvider()
        var usageEvents: [LLMService.TokenUsage] = []
        var contentChunks: [String] = []
        var thinkingChunks: [String] = []

        // Process each line as a streaming chunk
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                do {
                    try provider.handleStreamEvent(json, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            for try await chunk in stream {
                switch chunk {
                case .usage(let u): usageEvents.append(u)
                case .content(let c): contentChunks.append(c)
                case .thinking(let t): thinkingChunks.append(t)
                }
            }
        }

        // Should only have ONE usage event (from final chunk with finishReason)
        XCTAssertEqual(usageEvents.count, 1, "Should only yield usage once (on final chunk)")

        // Verify final usage values match the fixture's final chunk
        let finalUsage = usageEvents.first!
        XCTAssertEqual(finalUsage.input, 2927, "Input should be promptTokenCount")
        XCTAssertEqual(finalUsage.visibleOutput, 1120, "visibleOutput should be final candidatesTokenCount")
        XCTAssertEqual(finalUsage.reasoning, 819, "Reasoning should be thoughtsTokenCount")

        // Verify we got thinking chunks (lines 1-4 have thought: true)
        XCTAssertGreaterThan(thinkingChunks.count, 0, "Should have thinking chunks")

        // Verify we got content chunks
        XCTAssertGreaterThan(contentChunks.count, 0, "Should have content chunks")

        // Verify assembled content is valid JSON
        let assembledContent = contentChunks.joined()
        XCTAssertTrue(assembledContent.contains("\"summary\""), "Should contain summary")
        XCTAssertTrue(assembledContent.contains("\"annotations\""), "Should contain annotations")
    }

    @MainActor
    func testRealOpenAIStreamingFixture() async throws {
        let data = try getFixtureData(name: "analysis_gpt-5_2_stream.jsonl")
        let content = String(data: data, encoding: .utf8)!
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        let provider = OpenAIProvider()
        var usageEvents: [LLMService.TokenUsage] = []
        var contentChunks: [String] = []

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                do {
                    try provider.handleStreamEvent(json, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            for try await chunk in stream {
                switch chunk {
                case .usage(let u): usageEvents.append(u)
                case .content(let c): contentChunks.append(c)
                case .thinking: break
                }
            }
        }

        // Should only have ONE usage event (from response.completed)
        XCTAssertEqual(usageEvents.count, 1, "Should only yield usage once")

        // OpenAI: output_tokens (3248) INCLUDES reasoning_tokens (1607)
        // Normalized: output = 3248 - 1607 = 1641 (visible output only)
        let usage = usageEvents.first!
        XCTAssertEqual(usage.input, 8275, "Input tokens")
        XCTAssertEqual(usage.visibleOutput, 1641, "Output tokens (visible only, reasoning excluded)")
        XCTAssertEqual(usage.reasoning, 1607, "Reasoning tokens")

        // Verify content
        XCTAssertGreaterThan(contentChunks.count, 0, "Should have content")
    }

    @MainActor
    func testRealAnthropicStreamingFixture() async throws {
        let data = try getFixtureData(name: "analysis_sonnet-4_5_stream.jsonl")
        let content = String(data: data, encoding: .utf8)!
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        let provider = AnthropicProvider()
        var usageEvents: [LLMService.TokenUsage] = []
        var contentChunks: [String] = []
        var thinkingChunks: [String] = []

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                do {
                    try provider.handleStreamEvent(json, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            for try await chunk in stream {
                switch chunk {
                case .usage(let u): usageEvents.append(u)
                case .content(let c): contentChunks.append(c)
                case .thinking(let t): thinkingChunks.append(t)
                }
            }
        }

        // Should only have ONE usage event (from message_delta, not message_start)
        XCTAssertEqual(usageEvents.count, 1, "Should only yield usage once (from message_delta)")

        let usage = usageEvents.first!
        XCTAssertEqual(usage.input, 7572, "Input tokens")
        XCTAssertEqual(usage.visibleOutput, 6395, "Output tokens (not 6398 from double-counting)")

        // Verify content and thinking
        XCTAssertGreaterThan(contentChunks.count, 0, "Should have content")
        XCTAssertGreaterThan(thinkingChunks.count, 0, "Should have thinking chunks (extended thinking enabled)")
    }

    // MARK: - Streaming Error Handling Tests

    @MainActor
    func testGeminiStreamingErrorHandling() async throws {
        let provider = GeminiProvider()
        let errorChunk: [String: Any] = [
            "error": ["message": "API quota exceeded"]
        ]

        let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            do {
                try provider.handleStreamEvent(errorChunk, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        do {
            for try await _ in stream { }
            XCTFail("Should have thrown an error")
        } catch let error as LLMService.LLMError {
            if case .apiError(let message) = error {
                XCTAssertEqual(message, "API quota exceeded")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    @MainActor
    func testOpenAIStreamingErrorHandling() async throws {
        let provider = OpenAIProvider()
        let errorChunk: [String: Any] = [
            "type": "error",
            "error": ["message": "Rate limit exceeded"]
        ]

        let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            do {
                try provider.handleStreamEvent(errorChunk, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        do {
            for try await _ in stream { }
            XCTFail("Should have thrown an error")
        } catch let error as LLMService.LLMError {
            if case .apiError(let message) = error {
                XCTAssertEqual(message, "Rate limit exceeded")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    @MainActor
    func testAnthropicStreamingErrorHandling() async throws {
        let provider = AnthropicProvider()
        let errorChunk: [String: Any] = [
            "type": "error",
            "error": ["message": "Invalid API key"]
        ]

        let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            do {
                try provider.handleStreamEvent(errorChunk, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        do {
            for try await _ in stream { }
            XCTFail("Should have thrown an error")
        } catch let error as LLMService.LLMError {
            if case .apiError(let message) = error {
                XCTAssertEqual(message, "Invalid API key")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
}
