import XCTest
import GRDB
@testable import Reverie

final class BookProcessorCostAccountingTests: XCTestCase {
    @MainActor
    override func tearDown() async throws {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
        try await super.tearDown()
    }

    @MainActor
    func testImageLiveCostAccumulatesWithExistingTextCost() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let appState = AppState(database: database)
        appState.llmService = LLMService(appState: appState, session: session)
        appState.imageService = ImageService(session: session)
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
                let data = Self.analysisStreamResponse.data(using: .utf8)!
                return (response, data)
            }
            if url.contains(ImageModel.gemini25Flash.apiModel) {
                let data = #"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/jpeg","data":"aW1hZ2U="}}]}}]}"#.data(using: .utf8)!
                return (response, data)
            }

            let data = Self.summaryResponse.data(using: .utf8)!
            return (response, data)
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
