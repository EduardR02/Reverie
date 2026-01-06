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
        XCTAssertEqual(usage?.output, 1305 + 1033)
        
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
        
        let (text, _) = try provider.parseResponseText(from: data)
        let decoder = JSONDecoder()
        let analysis = try decoder.decode(LLMService.ChapterAnalysis.self, from: text.data(using: .utf8)!)
        
        XCTAssertGreaterThan(analysis.annotations.count, 0)
        XCTAssertFalse(analysis.summary.isEmpty)
    }

    @MainActor
    func testRealSonnet45AnalysisParsing() throws {
        let data = try getFixtureData(name: "analysis_sonnet-4_5.json")
        let provider = AnthropicProvider()
        
        let (text, _) = try provider.parseResponseText(from: data)
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
        
        XCTAssertEqual(usage?.input, 100)
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
        
        XCTAssertEqual(text, "Claude response")
        XCTAssertEqual(usage?.input, 411 + 100 + 50)
        XCTAssertEqual(usage?.cached, 50)
    }
}
