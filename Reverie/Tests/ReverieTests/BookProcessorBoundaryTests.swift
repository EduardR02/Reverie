import XCTest
import GRDB
@testable import Reverie

final class BookProcessorBoundaryTests: XCTestCase {
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
    func testEmptyBookFinishesWithoutConstructingInvalidRange() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let state = AppState(database: database, settings: UserSettings())
        var book = Book(title: "Empty book", author: "Author", epubPath: "empty.epub", chapterCount: 0)
        try database.saveBook(&book)

        await BookProcessor(appState: state, book: book).process()

        XCTAssertFalse(state.isProcessingBook)
        XCTAssertEqual(state.processingTotalChapters, 0)
        XCTAssertEqual(state.processingProgress, 1)
        XCTAssertTrue(try database.fetchChapters(for: book).isEmpty)
    }

    @MainActor
    func testCancellationDoesNotCountUnfinishedChapter() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let state = AppState(database: database, settings: UserSettings())
        var book = Book(title: "Book", author: "Author", epubPath: "book.epub", chapterCount: 1)
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Chapter text.</p>", wordCount: 2)
        chapter.summary = "Existing summary"
        try database.saveChapter(&chapter)
        let processor = BookProcessor(appState: state, book: book, isSimulation: true)
        let processing = Task { await processor.process() }
        await waitForInsightStart(state)

        processing.cancel()
        await processing.value

        XCTAssertFalse(state.isProcessingBook)
        XCTAssertEqual(state.processingCompletedChapters, 0)
        XCTAssertEqual(state.processingProgress, 0)
        XCTAssertEqual(state.processingInFlightInsights, 0)
        XCTAssertFalse(try XCTUnwrap(database.fetchChapters(for: book).first).processed)
    }

    @MainActor
    func testSimulationContextDoesNotPersistGeneratedSummary() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let state = AppState(database: database, settings: UserSettings())
        var book = Book(title: "Book", author: "Author", epubPath: "book.epub", chapterCount: 2)
        try database.saveBook(&book)
        for index in 0..<2 {
            var chapter = Chapter(bookId: book.id!, index: index, title: "Chapter \(index)", contentHTML: "<p>Some chapter content.</p>", wordCount: 3)
            try database.saveChapter(&chapter)
        }
        let processor = BookProcessor(appState: state, book: book, range: 1...1, includeContext: true, isSimulation: true)
        let processing = Task { await processor.process() }
        await waitForInsightStart(state)
        processing.cancel()
        await processing.value

        let chapters = try database.fetchChapters(for: book)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters.allSatisfy { $0.summary == nil && $0.rollingSummary == nil && !$0.processed })
    }

    @MainActor
    func testInvalidAnalysisDoesNotWriteOutputsOrAdvertiseCompletedBook() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let state = AppState(database: database, settings: UserSettings())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        state.llmService = LLMService(appState: state, session: URLSession(configuration: config))
        state.settings.llmProvider = .google
        state.settings.llmModel = SupportedModels.Google.gemini3FlashPreview
        state.settings.googleAPIKey = "mock-key"
        state.settings.imagesEnabled = false
        state.settings.webSearchEnabled = false
        state.settings.insightReasoningLevel = .off
        var book = Book(title: "Book", author: "Author", epubPath: "book.epub", chapterCount: 2)
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Chapter text.</p>", wordCount: 2)
        chapter.summary = "Existing summary"
        try database.saveChapter(&chapter)
        var next = Chapter(bookId: book.id!, index: 1, title: "Next", contentHTML: "<p>Later text.</p>", wordCount: 2)
        try database.saveChapter(&next)

        let analysis: [String: Any] = [
            "summary": "Chapter summary",
            "annotations": [["type": "science", "title": "Invalid anchor", "content": "An explanation", "sourceBlockId": 999]],
            "quizQuestions": [], "imageSuggestions": []
        ]
        let analysisText = String(decoding: try JSONSerialization.data(withJSONObject: analysis), as: UTF8.self)
        let event: [String: Any] = ["candidates": [["content": ["parts": [["text": analysisText]]]]]]
        let eventText = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        let streamData = Data("data: \(eventText)\n\ndata: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n".utf8)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (response, streamData)
        }

        await BookProcessor(appState: state, book: book).process()

        let savedChapter = try XCTUnwrap(database.fetchChapters(for: book).first)
        XCTAssertFalse(savedChapter.processed)
        XCTAssertEqual(savedChapter.summary, "Existing summary")
        XCTAssertTrue(try database.fetchAnnotations(for: savedChapter).isEmpty)
        XCTAssertTrue(try database.fetchQuizzes(for: savedChapter).isEmpty)
        XCTAssertFalse(try XCTUnwrap(database.fetchAllBooks().first).processedFully)
        XCTAssertEqual(state.processingCompletedChapters, 0)
        XCTAssertLessThan(state.processingProgress, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "Dependent chapter must not run after rejected context")
        XCTAssertFalse(try XCTUnwrap(database.fetchChapters(for: book).last).processed)
    }

    @MainActor
    func testAcceptedAnalysisSuppliesContinuityAndCoverageWithoutPreliminarySummaryCalls() async throws {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        var settings = UserSettings()
        settings.googleAPIKey = "synthetic-key"
        settings.imagesEnabled = false
        settings.webSearchEnabled = false
        let state = AppState(database: database, settings: settings)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        state.llmService = LLMService(appState: state, session: session)
        var book = Book(title: "Continuity", author: "Author", epubPath: "book.epub", chapterCount: 2)
        try database.saveBook(&book)
        for index in 0..<2 {
            let source = index == 0 ? "FIRST_CHAPTER_SOURCE" : "SECOND_CHAPTER_SOURCE"
            var chapter = Chapter(bookId: book.id!, index: index, title: "Chapter \(index)", contentHTML: "<p>\(source)</p>", wordCount: 1)
            chapter.summary = index == 0 ? "STALE_PRELIMINARY_SUMMARY" : "FUTURE_SUMMARY_SHOULD_NOT_LEAK"
            try database.saveChapter(&chapter)
        }
        let canonicalSummary = "The observers discover that the reference frame is accelerating."
        let coveredExplanation = "Tidal forces distinguish a spatially uniform acceleration from a varying gravitational field."
        let prompts = ProviderRequestLog()
        MockURLProtocol.requestHandler = { request in
            let body = try providerRequestJSON(request)
            prompts.append(body)
            let prompt = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            let first = !prompt.contains("SECOND_CHAPTER_SOURCE")
            let annotations: [[String: Any]] = first
                ? [["type": "science", "title": "Limits of equivalence", "content": coveredExplanation, "sourceBlockId": 1]]
                : []
            let analysis: [String: Any] = [
                "summary": first ? canonicalSummary : "The observation changes their next experiment.",
                "annotations": annotations, "quizQuestions": [], "imageSuggestions": []
            ]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: analysis), as: UTF8.self)
            let response: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: response))
        }

        await BookProcessor(appState: state, book: book).process()

        let calls = try prompts.snapshot().map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        XCTAssertEqual(calls.count, 2)
        let first = try XCTUnwrap(calls.first)
        let second = try XCTUnwrap(calls.last)
        XCTAssertFalse(first.contains(canonicalSummary))
        XCTAssertFalse(first.contains("SECOND_CHAPTER_SOURCE"))
        XCTAssertTrue(second.contains(canonicalSummary))
        XCTAssertTrue(second.contains(coveredExplanation))
        XCTAssertFalse(calls.contains { $0.contains("STALE_PRELIMINARY_SUMMARY") || $0.contains("FUTURE_SUMMARY_SHOULD_NOT_LEAK") })
        let chapters = try database.fetchChapters(for: book)
        XCTAssertTrue(chapters.allSatisfy(\.processed))
        XCTAssertEqual(chapters.first?.summary, canonicalSummary)
        XCTAssertTrue(chapters.last?.rollingSummary?.contains(canonicalSummary) == true)
        XCTAssertEqual(try database.fetchBook(id: book.id!)?.processedFully, true)
    }

    @MainActor
    private func waitForInsightStart(_ state: AppState) async {
        for _ in 0..<300 {
            if state.processingInFlightInsights > 0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected simulated insight work to start")
    }
}
