import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ReaderSessionTests: XCTestCase {
    var session: ReaderSession!
    var appState: AppState!
    var database: DatabaseService!

    override func setUp() async throws {
        try await super.setUp()
        let queue = try! DatabaseQueue()
        database = try! DatabaseService(dbQueue: queue)
        appState = AppState(database: database)
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        appState.llmService = LLMService(appState: appState, session: mockSession)
        appState.imageService = ImageService(session: mockSession)
        
        session = ReaderSession()
    }


    func test_setup_initializesChildComponents() {
        appState.settings.smartAutoScrollEnabled = true
        session.setup(with: appState)
        XCTAssertNotNil(session.analyzer)
        XCTAssertTrue(session.autoScroll.isActive) 
    }

    func test_handleAnnotationClick_setsScrollTarget() {
        let annotation = Annotation(id: 123, chapterId: 1, type: .science, title: "Title", content: "Content", sourceBlockId: 1)
        session.handleAnnotationClick(annotation)
        XCTAssertEqual(session.currentAnnotationId, 123)
        XCTAssertEqual(session.externalTabSelection, .insights)
    }

    func test_cleanup_stopsAllTasks() {
        session.setup(with: appState)
        session.cleanup()
        XCTAssertFalse(session.autoScroll.isActive)
    }

    func test_loadChapters_skipsClassificationWhenAlreadyComplete() async {
        // Given
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.classificationStatus = .completed
        book.importStatus = .complete
        try? database.saveBook(&book)
        appState.currentBook = book
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1")
        try? database.saveChapter(&chapter)
        
        session.setup(with: appState)
        
        var classificationCalled = false
        MockURLProtocol.requestHandler = { request in
            if request.url?.absoluteString.contains("chapter_classification") ?? false {
                classificationCalled = true
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{\"classifications\": []}".data(using: .utf8)!)
        }
        
        // When
        await session.loadChapters()
        
        // Give background tasks a moment
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        // Then
        XCTAssertFalse(classificationCalled)
    }

    func test_loadChapters_runsClassificationWhenPending() async {
        // Given
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.classificationStatus = .pending
        book.importStatus = .complete
        try? database.saveBook(&book)
        appState.currentBook = book
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1")
        try? database.saveChapter(&chapter)
        
        appState.settings.googleAPIKey = "key"
        session.setup(with: appState)
        
        let expectation = XCTestExpectation(description: "Classification called")
        MockURLProtocol.requestHandler = { request in
            if request.url?.absoluteString.contains("generativelanguage") ?? false {
                expectation.fulfill()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{\"classifications\": []}".data(using: .utf8)!)
        }
        
        // When
        await session.loadChapters()
        
        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_combinedWordCounts_addsInsightAndFootnoteWords() {
        let baseCounts = [2, 2]
        let baseTexts = ["Base words", "More words"]
        let annotation = Annotation(chapterId: 1, type: .science, title: "Extra", content: "Insight here", sourceBlockId: 1)
        let footnote = Footnote(chapterId: 1, marker: "1", content: "Footnote text", refId: "note1", sourceBlockId: 2)

        let combined = ReaderSession.combinedWordCounts(
            baseCounts: baseCounts,
            baseTexts: baseTexts,
            annotations: [annotation],
            footnotes: [footnote],
            chapterWordCount: 4
        )

        XCTAssertEqual(combined, [5, 4])
    }

    func test_combinedWordCounts_skipsEmbeddedFootnoteContent() {
        let baseCounts = [2, 2]
        let baseTexts = ["Base words", "More words"]
        let footnote = Footnote(chapterId: 1, marker: "1", content: "More words", refId: "note1", sourceBlockId: 2)

        let combined = ReaderSession.combinedWordCounts(
            baseCounts: baseCounts,
            baseTexts: baseTexts,
            annotations: [],
            footnotes: [footnote],
            chapterWordCount: 4
        )

        XCTAssertEqual(combined, baseCounts)
    }

    func test_wordCount_calculatesCorrectly() {
        // Basic case: "Hello world" (10 alphanumeric chars) -> 2 words
        XCTAssertEqual(ReaderSession.wordCount(in: "Hello world"), 2)
        
        // Punctuation ignored: "Hello, world!!!" -> still 2 words
        XCTAssertEqual(ReaderSession.wordCount(in: "Hello, world!!!"), 2)
        
        // Empty string -> 0 words
        XCTAssertEqual(ReaderSession.wordCount(in: ""), 0)
        
        // Short string (< 5 chars): "Hi" -> 0 words
        XCTAssertEqual(ReaderSession.wordCount(in: "Hi"), 0)
        
        // Numbers included: "Test123" (7 chars) -> 1 word
        XCTAssertEqual(ReaderSession.wordCount(in: "Test123"), 1)
        
        // Only special chars: "!@#$%^" -> 0 words
        XCTAssertEqual(ReaderSession.wordCount(in: "!@#$%^"), 0)
        
        // Mixed content: "Chapter 1: The Beginning!"
        // C h a p t e r (7) + 1 (1) + T h e (3) + B e g i n n i n g (9) = 20 alphanum
        // 20 / 5 = 4 words
        XCTAssertEqual(ReaderSession.wordCount(in: "Chapter 1: The Beginning!"), 4)
    }

    func test_loadChapter_guard_skipsSameChapterWithoutForce() async {
        // Given
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.importStatus = .complete
        try? database.saveBook(&book)
        appState.currentBook = book
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1")
        try? database.saveChapter(&chapter)
        
        session.setup(with: appState)
        await session.loadChapters() // Loads chapter 0
        
        let originalChapterId = session.currentChapter?.id
        XCTAssertNotNil(originalChapterId)
        
        // Reset scrollToPercent to check if it's touched again
        session.scrollToPercent = nil
        
        // When
        await session.loadChapter(at: 0, force: false)
        
        // Then
        XCTAssertNil(session.scrollToPercent)
    }
    
    func test_loadChapter_guard_proceedsWithForce() async {
        // Given
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.importStatus = .complete
        try? database.saveBook(&book)
        appState.currentBook = book
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1")
        try? database.saveChapter(&chapter)
        
        session.setup(with: appState)
        await session.loadChapters()
        
        session.lastScrollOffset = 123.45
        session.scrollToOffset = nil // Reset before forced reload
        
        // When
        await session.loadChapter(at: 0, force: true)
        
        // Then
        XCTAssertEqual(session.scrollToOffset, 123.45)
    }
}
