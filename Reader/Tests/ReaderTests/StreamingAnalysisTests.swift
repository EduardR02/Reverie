import XCTest
@testable import Reader

final class StreamingAnalysisTests: XCTestCase {
    
    func testStreamingScanner() {
        var scanner = StreamingJSONScanner()
        
        // Simulating chunks of a JSON response
        let chunks = [
            "{ \"annotations\": [", 
            " { \"title\": \"Insight 1\", \"content\": \"...\" },",
            " { \"title\" : \"Insight 2\", \"content\": \"...\" }", // Space before colon
            "], \"quizQuestions\": [", 
            " { \"question\": \"Q1?\", \"answer\": \"...\" }",
            "] }"
        ]
        
        var totalInsights = 0
        var totalQuizzes = 0
        
        for chunk in chunks {
            let (newInsights, newQuizzes) = scanner.update(with: chunk)
            totalInsights += newInsights
            totalQuizzes += newQuizzes
        }
        
        XCTAssertEqual(totalInsights, 2)
        XCTAssertEqual(totalQuizzes, 1)
    }
    
    func testStreamingScannerPartialKeys() {
        var scanner = StreamingJSONScanner()
        
        // Key "title" split across chunks
        let chunk1 = "{ \"annotations\": [ { \"ti"
        let chunk2 = "tle\": \"Insight\" } ] }"
        
        let (i1, _) = scanner.update(with: chunk1)
        XCTAssertEqual(i1, 0)
        
        let (i2, _) = scanner.update(with: chunk2)
        XCTAssertEqual(i2, 1)
    }

    @MainActor
    func testStreamChapterAnalysisEvents() async throws {
        let service = LLMService()
        let stream = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            continuation.yield(.thinking("Thinking..."))
            continuation.yield(.content("{ \"annotations\": ["))
            continuation.yield(.content("{ \"type\": \"science\", \"ti"))
            continuation.yield(.content("tle\": \"Insight\", \"content\": \"...\", \"sourceBlockId\": 1 }"))
            continuation.yield(.content("], \"quizQuestions\": ["))
            continuation.yield(.content("{ \"question\": \"Q?\", \"answer\": \"A\", \"sourceBlockId\": 2 }"))
            continuation.yield(.content("], \"summary\": \"Sum\" }"))
            continuation.finish()
        }

        let eventStream = service.streamChapterAnalysisEvents(from: stream)
        var insights = 0
        var quizzes = 0
        var didThink = false
        var finalAnalysis: LLMService.ChapterAnalysis?

        for try await event in eventStream {
            switch event {
            case .thinking:
                didThink = true
            case .insightFound:
                insights += 1
            case .quizQuestionFound:
                quizzes += 1
            case .usage:
                break
            case .completed(let analysis):
                finalAnalysis = analysis
            }
        }

        XCTAssertTrue(didThink)
        XCTAssertEqual(insights, 1)
        XCTAssertEqual(quizzes, 1)
        XCTAssertEqual(finalAnalysis?.summary, "Sum")
        XCTAssertEqual(finalAnalysis?.annotations.count, 1)
        XCTAssertEqual(finalAnalysis?.quizQuestions.count, 1)
    }

    @MainActor
    func testDecodeStructuredRobustness() throws {
        let service = LLMService()
        let json = "{ \"annotations\": [], \"quizQuestions\": [], \"imageSuggestions\": [], \"summary\": \"Test\" }"
        
        // Test Case 1: Direct JSON
        let d1: LLMService.ChapterAnalysis = try service.decodeStructured(LLMService.ChapterAnalysis.self, from: json)
        XCTAssertEqual(d1.summary, "Test")
        
        // Test Case 2: Markdown wrapped
        let md = "Here is the result:\n```json\n\(json)\n```\nHope it helps!"
        let d2: LLMService.ChapterAnalysis = try service.decodeStructured(LLMService.ChapterAnalysis.self, from: md)
        XCTAssertEqual(d2.summary, "Test")
        
        // Test Case 3: Messy preamble and POST-AMBLE (Gemini style) with braces in preamble
        let junk = "Here is a tiny object { \"status\": \"ok\" } and then the REAL data: { \"summary\": \"Direct\" } more junk including braces } and junk"
        let d3: LLMService.ChapterAnalysis = try service.decodeStructured(LLMService.ChapterAnalysis.self, from: junk)
        XCTAssertEqual(d3.summary, "Direct")
        
        // Test Case 4: Braces inside strings
        let nested = "{ \"summary\": \"Nested { braces } and escaped \\\" quotes\" } followed by junk"
        let d4: LLMService.ChapterAnalysis = try service.decodeStructured(LLMService.ChapterAnalysis.self, from: nested)
        XCTAssertEqual(d4.summary, "Nested { braces } and escaped \" quotes")
    }

    func testStreamingScannerAggressive() {
        var scanner = StreamingJSONScanner()
        
        // Test Case 1: Split keys at every possible position
        let fullJSON = "{ \"annotations\": [ { \"title\": \"X\" } ], \"quizQuestions\": [ { \"question\": \"Y\" } ] }"
        var foundInsights = 0
        var foundQuizzes = 0
        
        for char in fullJSON {
            let (i, q) = scanner.update(with: String(char))
            foundInsights += i
            foundQuizzes += q
        }
        XCTAssertEqual(foundInsights, 1)
        XCTAssertEqual(foundQuizzes, 1)
        
        // Test Case 2: False positives in content
        scanner.reset()
        let trickyJSON = """
        {
          \"annotations\": [
            { \"title\": \"The word \\\"title\\\": should not trigger twice\" }
          ]
        }
        """
        let (i2, _) = scanner.update(with: trickyJSON)
        XCTAssertEqual(i2, 1, "Should only find the key, not the word inside the string")
        
        // Test Case 3: Unicode split
        scanner.reset()
        // 􀒚 is a multi-byte character
        let unicode = "{ \"title\": \"Insight 􀒚\" }"
        let utf8Bytes = Array(unicode.utf8)
        let mid = utf8Bytes.count / 2
        
        let chunk1 = String(decoding: utf8Bytes[..<mid], as: UTF8.self)
        let chunk2 = String(decoding: utf8Bytes[mid...], as: UTF8.self)
        
        let (i3a, _) = scanner.update(with: chunk1)
        let (i3b, _) = scanner.update(with: chunk2)
        XCTAssertEqual(i3a + i3b, 1)
    }
}
