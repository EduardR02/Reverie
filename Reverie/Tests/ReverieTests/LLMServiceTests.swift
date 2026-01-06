import XCTest
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
                settings: settings
            )
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Quota exceeded"))
        }
    }
}

// MARK: - Mock Infrastructure

@MainActor
class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubResponseData: Data?
    nonisolated(unsafe) static var stubResponse: URLResponse?
    nonisolated(unsafe) static var stubError: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = MockURLProtocol.stubError {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            if let response = MockURLProtocol.stubResponse {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data = MockURLProtocol.stubResponseData {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
