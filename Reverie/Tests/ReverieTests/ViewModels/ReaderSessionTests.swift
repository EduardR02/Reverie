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
        // Autoscroll should not auto-start on setup anymore, even if enabled in settings
        XCTAssertFalse(session.autoScroll.isActive) 
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

    func test_loadChapter_withPendingAnchorPrefersAnchorOverScrollRestore() async {
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.importStatus = .complete
        try? database.saveBook(&book)
        appState.currentBook = book

        var chapter1 = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1", resourcePath: "c1.xhtml")
        var chapter2 = Chapter(bookId: book.id!, index: 1, title: "C2", contentHTML: "p2", resourcePath: "c2.xhtml")
        try? database.saveChapter(&chapter1)
        try? database.saveChapter(&chapter2)

        session.setup(with: appState)
        await session.loadChapters()

        session.lastScrollOffset = 321
        session.lastScrollPercent = 0.6
        session.pendingAnchor = "note-7"
        session.scrollToOffset = 999
        session.scrollToPercent = 0.9

        await session.loadChapter(at: 1)

        XCTAssertEqual(session.currentChapter?.id, chapter2.id)
        XCTAssertEqual(session.scrollToQuote, "note-7")
        XCTAssertNil(session.scrollToOffset)
        XCTAssertNil(session.scrollToPercent)
        XCTAssertNil(session.pendingAnchor)
        XCTAssertEqual(session.lastScrollOffset, 0)
        XCTAssertEqual(session.lastScrollPercent, 0)
    }

    func test_logicalBlocks_reusesCachedContentTextMarkers() {
        let blocks = ReaderSession.logicalBlocks(
            contentText: "[1] First block\nwith a second line.\n\n[2] Second block",
            html: "<p>ignored</p>"
        )

        XCTAssertEqual(blocks.map(\.id), [1, 2])
        XCTAssertEqual(blocks[0].text, "First block\nwith a second line.")
        XCTAssertEqual(blocks[1].text, "Second block")
    }

    func test_loadChapter_defersRSVPPreparationUntilModeEnabled() async throws {
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.importStatus = .complete
        try database.saveBook(&book)
        appState.currentBook = book

        var chapter = Chapter(
            bookId: book.id!,
            index: 0,
            title: "C1",
            contentHTML: "<p>Alpha beta gamma</p>",
            contentText: "[1] Alpha beta gamma",
            blockCount: 1
        )
        try database.saveChapter(&chapter)

        session.setup(with: appState)
        await session.loadChapters()

        XCTAssertTrue(session.rsvpEngine.words.isEmpty)

        session.setRSVPMode(true)
        await waitForRSVPWords(count: 3)

        XCTAssertEqual(session.rsvpEngine.words.map(\.text), ["Alpha", "beta", "gamma"])
    }

    func test_retryImage_doesNotMutateVisibleImagesAfterChapterChange() async throws {
        var book = Book(title: "Book", author: "Author", epubPath: "")
        book.importStatus = .complete
        book.classificationStatus = .completed
        try database.saveBook(&book)
        appState.currentBook = book

        var chapter1 = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "<p>One</p>")
        var chapter2 = Chapter(bookId: book.id!, index: 1, title: "C2", contentHTML: "<p>Two</p>")
        try database.saveChapter(&chapter1)
        try database.saveChapter(&chapter2)

        var failedImage = GeneratedImage(
            chapterId: chapter1.id!,
            excerpt: "Excerpt",
            prompt: "Wrapped prompt",
            imagePath: "",
            sourceBlockId: 1,
            status: .failed,
            failureReason: "old"
        )
        try database.saveImage(&failedImage)

        appState.settings.autoAIProcessingEnabled = false
        appState.settings.googleAPIKey = "key"

        session.setup(with: appState)
        await session.loadChapters()

        XCTAssertEqual(session.currentChapter?.id, chapter1.id)
        XCTAssertEqual(session.images.count, 1)

        MockURLProtocol.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.2)
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":{"message":"new failure reason","code":400}}"#.data(using: .utf8)!
            return (response, data)
        }

        let imageToRetry = try XCTUnwrap(session.images.first)
        let retryTask = Task {
            await session.retryImage(imageToRetry)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await session.loadChapter(at: 1)
        await retryTask.value

        XCTAssertEqual(session.currentChapter?.id, chapter2.id)
        XCTAssertTrue(session.images.isEmpty)

        let chapter1Images = try database.fetchImages(for: chapter1)
        XCTAssertEqual(chapter1Images.count, 1)
        XCTAssertEqual(chapter1Images[0].failureReason, "new failure reason")
    }

    func test_handleImageMarkerDoubleClick_ignoresFailedImages() {
        session.images = [
            GeneratedImage(
                id: 1,
                chapterId: 1,
                excerpt: "Failed excerpt",
                prompt: "Failed prompt",
                imagePath: "",
                sourceBlockId: 1,
                status: .failed,
                failureReason: "failed"
            ),
            GeneratedImage(
                id: 2,
                chapterId: 1,
                excerpt: "Success excerpt",
                prompt: "Success prompt",
                imagePath: "/tmp/test.png",
                sourceBlockId: 1,
                status: .success,
                failureReason: nil
            )
        ]

        session.handleImageMarkerDoubleClick(1)
        XCTAssertNil(session.expandedImage)

        session.handleImageMarkerDoubleClick(2)
        XCTAssertEqual(session.expandedImage?.id, 2)
    }

    private func waitForRSVPWords(count: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if session.rsvpEngine.words.count == count {
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for RSVP words")
    }
}
