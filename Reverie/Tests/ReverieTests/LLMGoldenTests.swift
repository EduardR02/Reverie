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
        
        #if SWIFT_PACKAGE
        // Strategy 2: Check via Bundle.module (SPM resources)
        if let bundleURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
            return try Data(contentsOf: bundleURL)
        }
        #endif
        
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
            "status": "completed",
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
            "stop_reason": "end_turn",
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

        // Anthropic reports base input, cache writes, and cache reads separately.
        // TokenUsage.input stores total input so cached-token subtraction pricing stays correct.
        XCTAssertEqual(text, "Claude response")
        XCTAssertEqual(usage?.input, 561)
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
    func testGeminiUsageSnapshotsRemainSeparateFromVisibleDeltas() throws {
        let provider = GeminiProvider()
        let intermediate: [String: Any] = [
            "candidates": [["content": ["parts": [["text": "Hello"]]]]],
            "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 10]
        ]
        let final: [String: Any] = [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["text": " World"]]]]],
            "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 50, "thoughtsTokenCount": 20]
        ]
        var text = ""
        for event in [intermediate, final] {
            try provider.handleStreamEvent(event) { chunk in
                if case .content(let delta) = chunk { text += delta }
                if case .usage = chunk { XCTFail("Transport owns cumulative usage normalization") }
            }
        }
        XCTAssertEqual(text, "Hello World")
        XCTAssertEqual(provider.observedUsage(fromStreamEvent: intermediate)?.visibleOutput, 10)
        XCTAssertNil(provider.usage(fromStreamEvent: intermediate))
        let usage = try XCTUnwrap(provider.usage(fromStreamEvent: final))
        XCTAssertEqual(usage.input, 100)
        XCTAssertEqual(usage.visibleOutput, 50)
        XCTAssertEqual(usage.reasoning, 20)
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

        let capturedUsage = provider.observedUsage(fromStreamEvent: chunk)

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

            if let usage = provider.usage(fromStreamEvent: json) { usageEvents.append(usage) }
            let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                do {
                    try provider.handleStreamEvent(json, emit: { chunk in continuation.yield(chunk) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            for try await chunk in stream {
                switch chunk {
                case .usage: XCTFail("Provider deltas must not emit cumulative usage")
                case .content(let c): contentChunks.append(c)
                case .thinking(let t): thinkingChunks.append(t)
                }
            }
        }

        XCTAssertEqual(usageEvents.count, 1, "The fixture has one terminal usage snapshot")

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

            if let usage = provider.usage(fromStreamEvent: json) { usageEvents.append(usage) }
            let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                do {
                    try provider.handleStreamEvent(json, emit: { chunk in continuation.yield(chunk) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            for try await chunk in stream {
                switch chunk {
                case .usage: XCTFail("Provider deltas must not emit cumulative usage")
                case .content(let c): contentChunks.append(c)
                case .thinking: break
                }
            }
        }

        XCTAssertEqual(usageEvents.count, 1, "The fixture has one terminal usage snapshot")

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

            if let usage = provider.usage(fromStreamEvent: json) { usageEvents.append(usage) }
            let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                do {
                    try provider.handleStreamEvent(json, emit: { chunk in continuation.yield(chunk) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            for try await chunk in stream {
                switch chunk {
                case .usage: XCTFail("Provider deltas must not emit cumulative usage")
                case .content(let c): contentChunks.append(c)
                case .thinking(let t): thinkingChunks.append(t)
                }
            }
        }

        XCTAssertEqual(usageEvents.count, 2, "Both snapshots must remain available for transport accounting")
        XCTAssertEqual(usageEvents[0].input, 7572)
        XCTAssertEqual(usageEvents[1].visibleOutput, 6395)

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
                try provider.handleStreamEvent(errorChunk, emit: { chunk in continuation.yield(chunk) })
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
                try provider.handleStreamEvent(errorChunk, emit: { chunk in continuation.yield(chunk) })
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
                try provider.handleStreamEvent(errorChunk, emit: { chunk in continuation.yield(chunk) })
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
