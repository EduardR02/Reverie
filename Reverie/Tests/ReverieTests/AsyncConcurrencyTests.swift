import XCTest
@testable import Reverie

@MainActor
final class AsyncConcurrencyTests: XCTestCase {
    private var session: URLSession!
    private var llm: LLMService!

    override func setUp() async throws {
        try await super.setUp()
        resetStubs()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        llm = LLMService(session: session)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        resetStubs()
        try await super.tearDown()
    }

    private func resetStubs() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
    }

    func testConcurrentTextAndImageRequestsKeepTheirResponsesSeparate() async throws {
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let textResponse = try Self.summaryStream("Text response")
        let imageResponse = try JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["inlineData": ["mimeType": "image/png", "data": image.base64EncodedString()]]]]]]
        ])
        MockURLProtocol.requestHandler = { request in
            let isImage = request.url!.path.contains(ImageModel.gemini25Flash.apiModel)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, isImage ? imageResponse : textResponse)
        }
        var settings = UserSettings()
        settings.googleAPIKey = "test-key"
        settings.webSearchEnabled = false
        let images = ImageService(session: session)
        let service = llm!

        async let summary = service.generateSummary(contentWithBlocks: "[1] Chapter text.", rollingSummary: nil, settings: settings)
        async let generatedImage = images.generateImage(prompt: "Image request", model: .gemini25Flash, apiKey: "test-key")
        let (textResult, imageResult) = try await (summary, generatedImage)

        XCTAssertEqual(textResult.0, "Text response")
        XCTAssertEqual(imageResult, image)
    }

    func testFailedRequestDoesNotCancelIndependentRequest() async throws {
        let success = try Self.summaryStream("Independent success")
        MockURLProtocol.requestHandler = { request in
            let body = Self.requestBody(request)
            if body.contains("FAIL_THIS_REQUEST") {
                throw NSError(domain: "IndependentRequest", code: 41)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, success)
        }
        var settings = UserSettings()
        settings.googleAPIKey = "test-key"
        settings.webSearchEnabled = false
        let failure = Task {
            try await llm.generateSummary(contentWithBlocks: "[1] FAIL_THIS_REQUEST", rollingSummary: nil, settings: settings)
        }
        let successTask = Task {
            try await llm.generateSummary(contentWithBlocks: "[1] Independent chapter.", rollingSummary: nil, settings: settings)
        }

        let failedResult = await failure.result
        let successfulResult = try await successTask.value

        if case .failure(let error) = failedResult {
            XCTAssertEqual((error as NSError).domain, "IndependentRequest")
            XCTAssertEqual((error as NSError).code, 41)
        } else {
            XCTFail("The identified failing request must propagate its transport error.")
        }
        XCTAssertEqual(successfulResult.0, "Independent success")
    }

    func testAnalysisStreamPropagatesTransportFailure() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw NSError(domain: "AnalysisTransport", code: 73)
        }
        var settings = UserSettings()
        settings.googleAPIKey = "test-key"
        settings.webSearchEnabled = false
        let stream = llm.analyzeChapterStreaming(contentWithBlocks: "[1] Chapter text.", rollingSummary: nil, bookTitle: nil, author: nil, settings: settings)

        do {
            for try await _ in stream {}
            XCTFail("The stream must not complete successfully after transport failure.")
        } catch {
            XCTAssertEqual((error as NSError).domain, "AnalysisTransport")
            XCTAssertEqual((error as NSError).code, 73)
        }
    }

    nonisolated private static func summaryStream(_ text: String) throws -> Data {
        let summary = try JSONSerialization.data(withJSONObject: ["summary": text])
        let event = try JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["role": "model", "parts": [["text": String(decoding: summary, as: UTF8.self)]]], "finishReason": "STOP"]]
        ])
        return Data("data: \(String(decoding: event, as: UTF8.self))\n\n".utf8)
    }

    nonisolated private static func requestBody(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
