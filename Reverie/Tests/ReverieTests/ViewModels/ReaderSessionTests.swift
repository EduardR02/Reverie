import XCTest
import GRDB
import SwiftUI
@testable import Reverie

@MainActor
final class ReaderSessionTests: XCTestCase {
    var session: ReaderSession!
    var appState: AppState!
    var database: DatabaseService!
    private var savedUserSettings: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedUserSettings = UserDefaults.standard.data(forKey: "userSettings")
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
        let queue = try! DatabaseQueue()
        database = try! DatabaseService(dbQueue: queue)
        appState = AppState(database: database)
        appState.settings = UserSettings()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        appState.llmService = LLMService(appState: appState, session: mockSession)
        appState.imageService = ImageService(session: mockSession)
        
        session = ReaderSession()
    }

    override func tearDown() async throws {
        session?.cleanup()
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
        if let savedUserSettings {
            UserDefaults.standard.set(savedUserSettings, forKey: "userSettings")
        } else {
            UserDefaults.standard.removeObject(forKey: "userSettings")
        }
        try await super.tearDown()
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

    func test_tickersDoNotRetainSessionWhenCleanupIsMissed() {
        weak var weakSession: ReaderSession?

        do {
            let localSession = ReaderSession()
            localSession.setup(with: appState)
            localSession.startReadingTicker()
            weakSession = localSession
        }

        XCTAssertNil(weakSession)
    }

    func test_aiPanelListCachesUpdateWhenAssetsChange() {
        session.annotations = [
            Annotation(id: 1, chapterId: 1, type: .science, title: "Later", content: "", sourceBlockId: 5),
            Annotation(id: 2, chapterId: 1, type: .history, title: "Earlier", content: "", sourceBlockId: 2)
        ]
        session.quizzes = [
            Quiz(id: 10, chapterId: 1, question: "Later?", answer: "A", sourceBlockId: 8)
        ]
        session.images = [
            GeneratedImage(id: 20, chapterId: 1, prompt: "Later", imagePath: "/tmp/later.png", sourceBlockId: 9)
        ]

        XCTAssertEqual(session.orderedAnnotationItems, [
            AIPanelIndexedItem(id: 2, index: 1),
            AIPanelIndexedItem(id: 1, index: 0)
        ])
        XCTAssertEqual(session.orderedQuizItems, [AIPanelIndexedItem(id: 10, index: 0)])
        XCTAssertEqual(session.sortedImages.map(\.id), [20])

        session.annotations.append(Annotation(id: 3, chapterId: 1, type: .world, title: "First", content: "", sourceBlockId: 1))
        session.quizzes.append(Quiz(id: 11, chapterId: 1, question: "First?", answer: "B", sourceBlockId: 1))
        session.images.append(GeneratedImage(id: 21, chapterId: 1, prompt: "First", imagePath: "/tmp/first.png", sourceBlockId: 1))

        XCTAssertEqual(session.orderedAnnotationItems, [
            AIPanelIndexedItem(id: 3, index: 2),
            AIPanelIndexedItem(id: 2, index: 1),
            AIPanelIndexedItem(id: 1, index: 0)
        ])
        XCTAssertEqual(session.orderedQuizItems, [
            AIPanelIndexedItem(id: 11, index: 1),
            AIPanelIndexedItem(id: 10, index: 0)
        ])
        XCTAssertEqual(session.sortedImages.map(\.id), [21, 20])
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
        appState.settings.autoAIProcessingEnabled = true
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

    func test_duplicateAndInvalidChapterLoadsPreserveReadingSessionAndPendingNavigation() async throws {
        let chapter = configurePages()
        appState.readingSpeedTracker.startSession(
            chapterId: try XCTUnwrap(chapter.id), wordCount: 1_000,
            startPercent: 0.2, now: Date().addingTimeInterval(-120)
        )
        let original = try XCTUnwrap(appState.readingSpeedTracker.currentSession)
        session.handleScrollUpdate(context: pageContext(index: 0, count: 3, blockOffset: 0.2), chapter: chapter)
        session.turnPage(1)
        let requests = session.pageTurnRequests
        let location = session.currentLocation

        await session.loadChapter(at: 0)
        await session.loadChapter(at: 99)

        let current = try XCTUnwrap(appState.readingSpeedTracker.currentSession)
        XCTAssertEqual(current.startTime, original.startTime)
        XCTAssertEqual(current.chapterId, original.chapterId)
        XCTAssertEqual(current.startPercent, original.startPercent)
        XCTAssertEqual(session.pageTurnRequests, requests)
        XCTAssertEqual(session.currentLocation, location)
        XCTAssertEqual(session.pageIndex, 0)
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
    
    // MARK: - Background Task Retention
    
    func test_completed_background_task_removes_itself_from_registry() async {
        session.setup(with: appState)
        XCTAssertEqual(session.backgroundTaskCount, 0)
        
        let task = Task { @MainActor in
            // immediately completes — nothing to await
        }
        session.trackBackgroundTask(task)
        XCTAssertEqual(session.backgroundTaskCount, 1)
        
        // Wait for the task to complete and auto-remove
        _ = await task.value
        // Give the removal task a moment to execute
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertEqual(session.backgroundTaskCount, 0)
    }
    
    func test_cleanup_cancels_and_removes_active_background_tasks() async {
        session.setup(with: appState)
        
        // Create a long-running task that won't complete on its own
        let task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        session.trackBackgroundTask(task)
        XCTAssertEqual(session.backgroundTaskCount, 1)
        
        session.cleanup()
        
        // After cleanup, tasks are cancelled and removed
        XCTAssertEqual(session.backgroundTaskCount, 0)
        XCTAssertTrue(task.isCancelled)
    }

    func test_reopenRestoresSemanticLocationBeforeLayoutSpecificPixels() async throws {
        var book = Book(title: "Book", author: "Author", epubPath: "", chapterCount: 1)
        book.importStatus = .complete
        book.classificationStatus = .completed
        book.currentScrollOffset = 4800
        book.currentScrollPercent = 0.37
        book.currentBlockId = 1
        book.currentBlockOffset = 0.42
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Text</p>")
        try database.saveChapter(&chapter)
        appState.currentBook = book
        appState.settings.readingMode = .pages
        appState.settings.autoAIProcessingEnabled = false
        session.setup(with: appState)
        await session.loadChapters()
        XCTAssertEqual(session.scrollToLocation, BlockLocation(blockId: 1, offset: 0.42))
        XCTAssertNil(session.scrollToOffset)
        XCTAssertNil(session.scrollToPercent)
    }

    func test_chapterChangeClearsPageStateAndStaleNavigation() async {
        let chapter = configurePages()
        session.handleScrollUpdate(context: pageContext(index: 1, count: 4), chapter: chapter)
        session.turnPage(1)
        session.scrollToLocation = BlockLocation(blockId: 1, offset: 0.5)
        session.scrollToAnnotationId = 3
        await session.loadChapter(at: 1)
        XCTAssertNil(session.pageIndex)
        XCTAssertNil(session.pageCount)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)
        XCTAssertNil(session.scrollToLocation)
        XCTAssertNil(session.scrollToAnnotationId)
        XCTAssertFalse(session.isAtChapterBottom)
        XCTAssertEqual(session.scrollToPercent, 0)
    }

    func test_initialImageOnlyPageSelectsImagesWithoutPrimaryMarker() async throws {
        let chapter = try XCTUnwrap(configureStoredPages(chapterCount: 1).first)
        var image = GeneratedImage(
            chapterId: chapter.id!, prompt: "Visible", imagePath: "/tmp/visible.png", sourceBlockId: 1
        )
        try database.saveImage(&image)
        await session.loadChapter(at: 0)

        XCTAssertEqual(session.images.count, 1)
        XCTAssertTrue(session.annotations.isEmpty)
        XCTAssertNil(session.externalTabSelection, "A delayed Insights reset must not race the initial page report")
        session.handleScrollUpdate(
            context: pageContext(index: 0, count: 3, isProgrammatic: true, visibleImageIds: [image.id!]),
            chapter: chapter
        )

        XCTAssertEqual(session.aiPanelSelectedTab, .images)
        XCTAssertNil(session.currentImageId, "Restoration need not focus a particular image")

        session.lastAutoSwitchAt = 0
        session.handleScrollUpdate(
            context: pageContext(index: 1, count: 3, primaryType: "annotation", visibleAnnotationIds: [10]),
            chapter: chapter
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        session.handleScrollUpdate(
            context: pageContext(index: 2, count: 3, visibleImageIds: [image.id!]),
            chapter: chapter
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights, "Later navigation still follows primaryType, not visible counts")
    }

    func test_initialInsightAndEmptyPagesKeepInsightsWithoutInventingMarkerPriority() async throws {
        let chapters = try configureStoredPages()
        var annotation = Annotation(
            chapterId: chapters[0].id!, type: .science, title: "Insight", content: "Context", sourceBlockId: 1
        )
        try database.saveAnnotation(&annotation)
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(
            context: pageContext(index: 0, count: 3, isProgrammatic: true, visibleAnnotationIds: [annotation.id!]),
            chapter: chapters[0]
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)

        await session.loadChapter(at: 1)
        session.handleScrollUpdate(context: pageContext(index: 0, count: 3, isProgrammatic: true), chapter: chapters[1])
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)

        await session.loadChapter(at: 1, force: true)
        session.handleScrollUpdate(
            context: pageContext(
                index: 0, count: 3, isProgrammatic: true, visibleAnnotationIds: [10], visibleImageIds: [20]
            ),
            chapter: chapters[1]
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights, "Mixed content without a primary marker gets no new priority rule")
    }

    func test_initialImagePageHonorsDisabledContextAutoSwitch() async throws {
        let chapter = try XCTUnwrap(configureStoredPages(chapterCount: 1).first)
        appState.settings.autoSwitchContextTabs = false
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(
            context: pageContext(index: 0, count: 3, isProgrammatic: true, visibleImageIds: [20]),
            chapter: chapter
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        session.handleScrollUpdate(
            context: pageContext(index: 1, count: 3, primaryType: "image", visibleImageIds: [20]),
            chapter: chapter
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
    }

    func test_initialPagePreservesManualTabsAndChatEvenWhenSmartChatReturnIsEnabled() async throws {
        let chapter = try XCTUnwrap(configureStoredPages(chapterCount: 1).first)
        appState.settings.autoSwitchFromChatOnScroll = true
        for tab in [AIPanel.Tab.insights, .footnotes, .images, .chat] {
            await session.loadChapter(at: 0, force: true)
            session.aiPanelSelectedTab = tab
            session.handleScrollUpdate(
                context: pageContext(index: 0, count: 3, primaryType: "image", visibleImageIds: [20]),
                chapter: chapter
            )
            XCTAssertEqual(session.aiPanelSelectedTab, tab)
        }
    }

    func test_initialPagePreservesChoiceMadeBeforeChapterLoadAndPendingExternalSelection() async throws {
        let chapters = try configureStoredPages()
        session.aiPanelSelectedTab = .footnotes
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(
            context: pageContext(index: 0, count: 3, isProgrammatic: true, visibleImageIds: [20]),
            chapter: chapters[0]
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .footnotes)

        session.externalTabSelection = .chat
        await session.loadChapter(at: 1)
        session.handleScrollUpdate(
            context: pageContext(index: 0, count: 3, primaryType: "image", visibleImageIds: [20]),
            chapter: chapters[1]
        )
        XCTAssertEqual(session.externalTabSelection, .chat)
        XCTAssertEqual(session.aiPanelSelectedTab, .footnotes)
    }

    func test_initialPageHonorsSourceJumpSuppressionAcrossReloadWithoutChangingLaterNavigation() async throws {
        let chapter = try XCTUnwrap(configureStoredPages(chapterCount: 1).first)
        await session.loadChapter(at: 0)
        session.suppressContextAutoSwitch(for: 60)
        await session.loadChapter(at: 0, force: true)
        session.handleScrollUpdate(
            context: pageContext(index: 0, count: 3, isProgrammatic: true, visibleImageIds: [20]),
            chapter: chapter
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        session.suppressContextAutoSwitchUntil = 0
        session.handleScrollUpdate(
            context: pageContext(index: 1, count: 3, primaryType: "image", visibleImageIds: [20]),
            chapter: chapter
        )
        XCTAssertEqual(session.aiPanelSelectedTab, .images)
    }

    func test_initialImageSelectionRearmsForChapterReloadLayoutResetAndReopen() async throws {
        let chapters = try configureStoredPages()
        let imagePage = pageContext(index: 0, count: 3, isProgrammatic: true, visibleImageIds: [20])
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(context: imagePage, chapter: chapters[0])
        XCTAssertEqual(session.aiPanelSelectedTab, .images)

        session.aiPanelSelectedTab = .insights
        await session.loadChapter(at: 1)
        session.handleScrollUpdate(context: imagePage, chapter: chapters[1])
        XCTAssertEqual(session.aiPanelSelectedTab, .images)

        session.aiPanelSelectedTab = .insights
        await session.loadChapter(at: 1, force: true)
        session.handleScrollUpdate(context: imagePage, chapter: chapters[1])
        XCTAssertEqual(session.aiPanelSelectedTab, .images)

        session.aiPanelSelectedTab = .insights
        session.setPageLayout(.spread)
        session.lastAutoSwitchAt = 0
        session.handleScrollUpdate(context: imagePage, chapter: chapters[1])
        XCTAssertEqual(session.aiPanelSelectedTab, .images)

        session.cleanup()
        session = ReaderSession()
        session.setup(with: appState)
        session.chapters = chapters
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(context: imagePage, chapter: chapters[0])
        XCTAssertEqual(session.aiPanelSelectedTab, .images)
    }

    func test_readingModeDecodesLegacyPreferencesAndRoundTripsPages() throws {
        let legacy = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"fontSize":23,"autoSwitchToQuiz":false}"#.utf8))
        XCTAssertEqual(legacy.readingMode, .scroll)
        XCTAssertEqual(legacy.pageLayout, .spread)
        XCTAssertEqual(legacy.fontSize, 23)
        XCTAssertFalse(legacy.autoSwitchToQuiz)
        var paged = legacy
        paged.readingMode = .pages
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(paged)), paged)
        paged.pageLayout = .single
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(paged)).pageLayout, .single)
    }

    func test_pageModeStopsContinuousScrollAndClearsPendingTurnsOnExit() {
        let savedSettings = UserDefaults.standard.data(forKey: "userSettings")
        defer {
            if let savedSettings { UserDefaults.standard.set(savedSettings, forKey: "userSettings") }
            else { UserDefaults.standard.removeObject(forKey: "userSettings") }
        }
        let chapter = configurePages()
        appState.settings.readingMode = .scroll
        session.autoScroll.start()
        session.scrollByAmount = 40
        session.setReadingMode(.pages)
        XCTAssertFalse(session.autoScroll.isActive)
        XCTAssertNil(session.scrollByAmount)
        XCTAssertEqual(UserSettings.load().readingMode, .pages)
        session.handleScrollUpdate(context: pageContext(index: 0, count: 3), chapter: chapter)
        session.turnPage(1)
        XCTAssertEqual(session.pageTurnRequests.count, 1)
        session.setReadingMode(.scroll)
        XCTAssertNil(session.pageIndex)
        XCTAssertNil(session.pageCount)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)
        XCTAssertFalse(session.autoScroll.isActive)
    }

    func test_pageArrivalDoesNotOpenQuizUntilExplicitAdvance() {
        let chapter = configurePages()
        session.quizzes = [Quiz(id: 1, chapterId: 1, question: "Why?", answer: "Because", sourceBlockId: 1)]
        session.handleScrollUpdate(context: pageContext(index: 2, count: 3), chapter: chapter)
        XCTAssertTrue(session.isAtChapterBottom)
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        XCTAssertFalse(session.hasAutoSwitchedToQuiz)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(session.aiPanelSelectedTab, .quiz)
        XCTAssertEqual(appState.currentChapterIndex, 0)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(appState.currentChapterIndex, 1)
        XCTAssertNil(session.pageIndex)
    }

    func test_pageBoundaryAdvancesWithoutQuiz() {
        let chapter = configurePages()
        session.handleScrollUpdate(context: pageContext(index: 0, count: 1), chapter: chapter)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(appState.currentChapterIndex, 1)
    }

    func test_pageBoundaryAdvancesWithQuizAutoSwitchDisabled() {
        let chapter = configurePages()
        appState.settings.autoSwitchToQuiz = false
        session.quizzes = [Quiz(id: 1, chapterId: 1, question: "Why?", answer: "Because", sourceBlockId: 1)]
        session.handleScrollUpdate(context: pageContext(index: 0, count: 1), chapter: chapter)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(appState.currentChapterIndex, 1)
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
    }

    func test_finalBookPageHasNoInvalidChapterAdvance() {
        let chapter = configurePages(chapterCount: 1)
        session.handleScrollUpdate(context: pageContext(index: 0, count: 1), chapter: chapter)
        XCTAssertFalse(session.canAdvancePage)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(appState.currentChapterIndex, 0)
        XCTAssertEqual(session.pageIndex, 0)
    }

    func test_pageKeysRespectChatShiftTabsAndRSVPPrecedence() {
        let chapter = configurePages()
        session.handleScrollUpdate(context: pageContext(index: 1, count: 3), chapter: chapter)
        session.isChatInputFocused = true
        _ = session.handleReaderKey(.rightArrow)
        _ = session.handleReaderKey(.rightArrow, modifiers: .shift)
        _ = session.handleSpaceBar()
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)

        session.isChatInputFocused = false
        _ = session.handleReaderKey(.rightArrow, modifiers: .shift)
        XCTAssertNotEqual(session.aiPanelSelectedTab, .insights)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)
        _ = session.handleReaderKey(.rightArrow)
        _ = session.handleReaderKey(.leftArrow)
        _ = session.handleSpaceBar()
        XCTAssertEqual(session.pageTurnRequests.map(\.delta), [1, -1, 1])
        XCTAssertEqual(Set(session.pageTurnRequests.map(\.id)).count, 3)
        XCTAssertEqual(appState.currentChapterIndex, 0)
        XCTAssertNil(session.scrollByAmount)
        let ids = session.pageTurnRequests.map(\.id)
        session.consumePageTurns(ids)
        session.isRSVPMode = true
        _ = session.handleReaderKey(.rightArrow)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)
    }

    func test_pageProgressNeverLosesFurthestPositionWhenBacktracking() {
        let chapter = configurePages()
        session.calculatorCache.insert(ChapterProgressCalculator(wordCounts: [100], totalWords: 100), for: 1, protecting: nil)
        session.handleScrollUpdate(context: pageContext(index: 1, count: 4, blockOffset: 0.8), chapter: chapter)
        session.handleScrollUpdate(context: pageContext(index: 0, count: 4, blockOffset: 0.2), chapter: chapter)
        XCTAssertEqual(session.currentProgressPercent, 0.2, accuracy: 0.001)
        XCTAssertEqual(session.furthestProgressPercent, 0.8, accuracy: 0.001)
        session.handleScrollUpdate(context: pageContext(index: 3, count: 4), chapter: chapter)
        XCTAssertEqual(session.furthestProgressPercent, 1)
    }

    func test_pageBackAnchorUsesSemanticLocationRatherThanVirtualPixels() {
        let chapter = configurePages()
        session.handleScrollUpdate(context: pageContext(index: 1, count: 4, blockOffset: 0.4), chapter: chapter)
        session.setBackAnchor()
        session.handleScrollUpdate(context: pageContext(index: 2, count: 4, blockOffset: 0.7), chapter: chapter)
        session.returnToBackAnchor()
        XCTAssertEqual(session.scrollToLocation, BlockLocation(blockId: 1, offset: 0.4))
        XCTAssertNil(session.scrollToOffset)
        XCTAssertFalse(session.showBackButton)
    }

    func test_pageMetadataRejectsStaleChapterAndCleanupClearsPendingTurns() {
        let chapter = configurePages()
        let stale = Chapter(id: 99, bookId: 1, index: 1, title: "Stale", contentHTML: "<p>Old</p>")
        session.handleScrollUpdate(context: pageContext(index: 2, count: 3), chapter: stale)
        XCTAssertNil(session.pageIndex)
        session.handleScrollUpdate(context: pageContext(index: 1, count: 3), chapter: chapter)
        session.turnPage(1)
        session.cleanup()
        XCTAssertNil(session.pageIndex)
        XCTAssertNil(session.pageCount)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)
    }

    func test_contextWithoutLogicalBlockClearsCurrentSemanticAnchor() {
        let chapter = configurePages()
        session.handleScrollUpdate(context: pageContext(index: 1, count: 3, blockOffset: 0.5), chapter: chapter)
        XCTAssertEqual(session.currentLocation, BlockLocation(blockId: 1, offset: 0.5))
        let context = ScrollContext(
            annotationId: nil, imageId: nil, footnoteRefId: nil, blockId: nil,
            blockOffset: nil, primaryType: nil, scrollPercent: 0.5,
            scrollOffset: 600, viewportHeight: 600, scrollHeight: 1800,
            isProgrammatic: true, pageIndex: 1, pageCount: 3
        )
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertNil(session.currentLocation)
        XCTAssertEqual(session.furthestLocation, BlockLocation(blockId: 1, offset: 0.5))
    }

    func test_spreadLastPairAndOddTailUseVisibleSpanAndOnlyVisibleInsights() {
        let chapter = configurePages(chapterCount: 1)
        var paired = pageContext(index: 2, count: 4)
        paired.visiblePageCount = 2
        paired.visibleAnnotationIds = [10, 20]
        session.handleScrollUpdate(context: paired, chapter: chapter)
        XCTAssertTrue(session.isOnLastPage)
        XCTAssertEqual(session.visibleAnnotationIds, [10, 20])
        XCTAssertEqual(session.currentProgressPercent, 1)
        XCTAssertFalse(session.canAdvancePage)
        session.turnPage(1)
        XCTAssertTrue(session.pageTurnRequests.isEmpty)

        var oddTail = pageContext(index: 4, count: 5)
        oddTail.visiblePageCount = 2
        oddTail.visibleAnnotationIds = [30]
        session.handleScrollUpdate(context: oddTail, chapter: chapter)
        XCTAssertEqual(session.visiblePageCount, 1)
        XCTAssertEqual(session.visibleAnnotationIds, [30])
        XCTAssertTrue(session.isOnLastPage)
        session.cleanup()
        XCTAssertTrue(session.visibleAnnotationIds.isEmpty)
        XCTAssertNil(session.bookPageNumber)
    }

    func test_visibleChapterMeasurementFailureIsExplicitAndClearedOnCleanup() {
        let chapter = configurePages()
        var failed = pageContext(index: 0, count: 3)
        failed.paginationFailed = true
        session.handleScrollUpdate(context: failed, chapter: chapter)
        XCTAssertTrue(session.bookPaginationFailed)
        XCTAssertNil(session.bookPageCount)
        XCTAssertNil(session.bookPageNumber)
        session.cleanup()
        XCTAssertFalse(session.bookPaginationFailed)
    }

    func test_backFromFirstSpreadNavigatesToPreviousChapterFinalSpread() async throws {
        var book = Book(title: "Book", author: "Author", epubPath: "", chapterCount: 2)
        try database.saveBook(&book)
        var first = Chapter(bookId: book.id!, index: 0, title: "First", contentHTML: "<p>First</p>")
        var second = Chapter(bookId: book.id!, index: 1, title: "Second", contentHTML: "<p>Second</p>")
        try database.saveChapter(&first)
        try database.saveChapter(&second)
        appState.currentBook = book
        appState.settings.readingMode = .pages
        appState.settings.rsvpEnabled = false
        appState.settings.autoAIProcessingEnabled = false
        appState.currentChapterIndex = 1
        session.setup(with: appState)
        session.chapters = [first, second]
        session.currentChapter = second
        session.didRestoreInitialPosition = true
        session.handleScrollUpdate(context: pageContext(index: 0, count: 5), chapter: second)
        session.turnPage(-1)
        XCTAssertEqual(appState.currentChapterIndex, 0)
        await session.loadChapter(at: 0)
        XCTAssertEqual(session.scrollToPercent, 1)
        XCTAssertNil(session.scrollToLocation)
        XCTAssertNil(session.scrollToOffset)
    }

    func test_quizSelectionIsUnavailableUntilLastScreenAndClosesOnBackwardNavigation() {
        let chapter = configurePages()
        session.quizzes = [Quiz(id: 1, chapterId: 1, question: "Why?", answer: "Because", sourceBlockId: 1)]
        var context = pageContext(index: 0, count: 5)
        context.visiblePageCount = 2
        context.pageCapacity = 2
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertFalse(session.isQuizAvailable)
        session.aiPanelSelectedTab = .quiz
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        session.externalTabSelection = .quiz
        XCTAssertNil(session.externalTabSelection)
        session.aiPanelSelectedTab = .images
        session.cycleAIPanelTab(direction: 1)
        XCTAssertEqual(session.aiPanelSelectedTab, .footnotes)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertNotEqual(session.aiPanelSelectedTab, .quiz)

        context.pageIndex = 4
        context.visiblePageCount = 1
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertTrue(session.isQuizAvailable)
        session.externalTabSelection = .quiz
        XCTAssertEqual(session.externalTabSelection, .quiz)
        session.aiPanelSelectedTab = .quiz
        XCTAssertEqual(session.aiPanelSelectedTab, .quiz)
        context.pageIndex = 2
        context.visiblePageCount = 2
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        XCTAssertNil(session.externalTabSelection)
        XCTAssertEqual(session.quizzes.count, 1)
    }

    func test_scrollAndRSVPKeepQuizAvailableBeforeChapterEnd() {
        let chapter = configurePages()
        session.handleScrollUpdate(context: pageContext(index: 0, count: 5), chapter: chapter)
        session.isRSVPMode = true
        XCTAssertTrue(session.isQuizAvailable)
        session.aiPanelSelectedTab = .quiz
        XCTAssertEqual(session.aiPanelSelectedTab, .quiz)
        session.isRSVPMode = false
        appState.settings.readingMode = .scroll
        session.readingModeDidChange()
        XCTAssertTrue(session.isQuizAvailable)
        session.aiPanelSelectedTab = .quiz
        session.externalTabSelection = .quiz
        XCTAssertEqual(session.aiPanelSelectedTab, .quiz)
        XCTAssertEqual(session.externalTabSelection, .quiz)
    }

    func test_pageImagesAreFilteredByVisibleIDsIncludingFailedRetriesWithoutMutatingChapterAssets() {
        let chapter = configurePages()
        session.images = [
            GeneratedImage(id: 1, chapterId: 1, prompt: "Visible", imagePath: "/tmp/one.png", sourceBlockId: 1),
            GeneratedImage(id: 2, chapterId: 1, prompt: "Off screen", imagePath: "/tmp/two.png", sourceBlockId: 2),
            GeneratedImage(id: 3, chapterId: 1, prompt: "Retry", imagePath: "", sourceBlockId: 3, status: .failed, failureReason: "Failed")
        ]
        var context = pageContext(index: 0, count: 5)
        context.visibleImageIds = [1, 3]
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertEqual(session.visibleImageIds, [1, 3])
        let visible = AIPanel.contextualImages(session.sortedImages, visibleIds: session.visibleImageIds, isPageMode: true)
        XCTAssertEqual(visible.map(\.id), [1, 3])
        XCTAssertEqual(visible.last?.status, .failed)
        XCTAssertEqual(session.images.count, 3)
        XCTAssertEqual(session.sortedImages.count, 3)

        context.pageIndex = 4
        context.visibleImageIds = []
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertTrue(AIPanel.contextualImages(session.sortedImages, visibleIds: session.visibleImageIds, isPageMode: true).isEmpty)
        appState.settings.readingMode = .scroll
        session.handleScrollUpdate(context: context, chapter: chapter)
        XCTAssertTrue(session.visibleImageIds.isEmpty)
        XCTAssertEqual(AIPanel.contextualImages(session.sortedImages, visibleIds: [], isPageMode: false).map(\.id), [1, 2, 3])
    }

    func test_cachedBookCountsAndExactScreenNumberSurviveForwardAndBackwardChapterLoads() async throws {
        let chapters = try configureStoredPages()
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapters[0], index: 0, count: 1), chapter: chapters[0])
        let deadline = Date().addingTimeInterval(15)
        while session.bookPageCount == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.bookPageCount, 2)
        XCTAssertEqual(session.bookPageNumber, 1)
        XCTAssertEqual(session.paginationAssetFetchCount, 1)

        session.turnPage(1)
        XCTAssertNil(session.pageIndex, "Local page metadata is unknown until the new document reports it")
        XCTAssertEqual(session.bookPageCount, 2)
        XCTAssertEqual(session.bookPageNumber, 2, "The exact target first screen is already known")
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapters[0], index: 0, count: 1), chapter: chapters[0])
        XCTAssertNil(session.pageIndex, "Late metadata from the departed chapter must not undo the boundary")
        await session.loadChapter(at: 1)
        XCTAssertEqual(session.bookPageCount, 2)
        XCTAssertEqual(session.bookPageNumber, 2)
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapters[1], index: 0, count: 1), chapter: chapters[1])
        XCTAssertEqual(session.bookPageCount, 2, "A cached chapter switch must not publish an unknown total")
        XCTAssertEqual(session.bookPageNumber, 2)
        try await waitForBaseContent(chapter: chapters[1])

        session.chapters[1].processed = true
        session.chapters[1].summary = "New analysis metadata does not change the reader document."
        XCTAssertEqual(session.bookPageCount, 2)
        session.turnPage(-1)
        XCTAssertEqual(session.bookPageCount, 2)
        XCTAssertEqual(session.bookPageNumber, 1, "The exact previous chapter final screen is already known")
        await session.loadChapter(at: 0)
        XCTAssertEqual(session.scrollToPercent, 1)
        XCTAssertEqual(session.bookPageCount, 2)
        XCTAssertEqual(session.bookPageNumber, 1)
        try await waitForBaseContent(chapter: chapters[0])
        XCTAssertEqual(session.baseContentBuildCount, 2, "Revisiting unchanged chapters must reuse their parsed blocks")
        XCTAssertEqual(session.paginationAssetFetchCount, 1, "Boundary measurements must reuse the book's compact asset snapshots")
    }

    func test_paginationInvalidatesOnlyPageAffectingAssetsAndContent() async throws {
        let chapter = try XCTUnwrap(configureStoredPages(chapterCount: 1).first)
        await session.loadChapter(at: 0)
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapter, index: 0, count: 3), chapter: chapter)
        XCTAssertEqual(session.bookPageCount, 3)
        session.annotations.append(Annotation(id: 10, chapterId: chapter.id!, type: .science, title: "A", content: "B", sourceBlockId: 1))
        XCTAssertNil(session.bookPageCount, "Inline-block annotation markers can change wrapping")
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapter, index: 0, count: 3), chapter: chapter)
        XCTAssertEqual(session.bookPageCount, 3)
        session.annotations[0].content = "Only sidebar prose changed"
        XCTAssertEqual(session.bookPageCount, 3)

        session.images = [GeneratedImage(id: 20, chapterId: chapter.id!, prompt: "P", imagePath: "", sourceBlockId: 1, status: .failed)]
        XCTAssertNil(session.bookPageCount, "Adding an image marker affects wrapping even with inline images off")
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapter, index: 0, count: 3), chapter: chapter)
        session.images[0].status = .success
        session.images[0].imagePath = "/tmp/new-successful-image.png"
        XCTAssertEqual(session.bookPageCount, 3, "A non-inline image URL/status is sidebar-only")

        appState.settings.inlineAIImages = true
        var awaitingMeasurement = pageContext(index: 0, count: 3)
        awaitingMeasurement.viewportWidth = 900
        session.handleScrollUpdate(context: awaitingMeasurement, chapter: chapter)
        XCTAssertNil(session.bookPageCount, "Do not reuse totals after enabling inline images")
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapter, index: 0, count: 5), chapter: chapter)
        XCTAssertEqual(session.bookPageCount, 5)
        session.images[0].imagePath = "/tmp/replaced-successful-image.png"
        XCTAssertNil(session.bookPageCount, "A rendered inline image URL changes layout identity")
        session.handleScrollUpdate(context: measuredPageContext(chapter: chapter, index: 0, count: 6), chapter: chapter)
        XCTAssertEqual(session.bookPageCount, 6)
        session.chapters[0].contentHTML = "<p>Changed publication content</p>"
        XCTAssertNil(session.bookPageCount)
    }

    func test_baseContentCacheReusesUnchangedSourcesButRefreshesChangedChapterText() async throws {
        var chapter = try XCTUnwrap(configureStoredPages(chapterCount: 1).first)
        await session.loadChapter(at: 0)
        session.setRSVPMode(true)
        await waitForRSVPWords(count: 3)
        XCTAssertEqual(session.rsvpEngine.words.map(\.text), ["Alpha", "beta", "gamma"])
        XCTAssertEqual(session.baseContentBuildCount, 1, "RSVP and progress must share one parse")

        chapter.contentText = "[1] Delta epsilon"
        chapter.contentHTML = "<p>Delta epsilon</p>"
        session.chapters[0] = chapter
        await session.loadChapter(at: 0, force: true)
        await waitForRSVPWords(count: 2)
        XCTAssertEqual(session.rsvpEngine.words.map(\.text), ["Delta", "epsilon"])
        try await waitForBaseContent(chapter: chapter)
        let deadline = Date().addingTimeInterval(2)
        while session.calculatorCache.get(for: chapter.id!) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.baseContentBuildCount, 2)
        let calculator = try XCTUnwrap(session.calculatorCache.get(for: chapter.id!))
        XCTAssertEqual(calculator.totalWords, ReaderSession.wordCount(in: "Delta epsilon"))
    }

    func test_baseContentCacheIsBoundedAndOnlyEvictedChaptersNeedReparsing() async throws {
        let chapters = try configureStoredPages(chapterCount: 22)
        for index in chapters.indices {
            appState.currentChapterIndex = index
            await session.loadChapter(at: index)
            try await waitForBaseContent(chapter: chapters[index])
        }
        XCTAssertEqual(session.baseContentBuildCount, 22)
        XCTAssertEqual(session.cachedBaseContentChapterIDs.count, 20)
        XCTAssertFalse(session.cachedBaseContentChapterIDs.contains(chapters[0].id!))

        appState.currentChapterIndex = 20
        await session.loadChapter(at: 20)
        XCTAssertEqual(session.baseContentBuildCount, 22)
        appState.currentChapterIndex = 0
        await session.loadChapter(at: 0)
        try await waitForBaseContent(chapter: chapters[0])
        XCTAssertEqual(session.baseContentBuildCount, 23)
        XCTAssertEqual(session.cachedBaseContentChapterIDs.count, 20)
        XCTAssertTrue(session.cachedBaseContentChapterIDs.contains(chapters[0].id!))
    }

    private func waitForBaseContent(chapter: Chapter) async throws {
        let id = try XCTUnwrap(chapter.id)
        let deadline = Date().addingTimeInterval(2)
        while !session.cachedBaseContentChapterIDs.contains(id), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.cachedBaseContentChapterIDs.contains(id), "Chapter parse did not settle")
    }

    private func configureStoredPages(chapterCount: Int = 2) throws -> [Chapter] {
        var book = Book(title: "Book", author: "Author", epubPath: "", chapterCount: chapterCount)
        book.importStatus = .complete
        book.classificationStatus = .completed
        try database.saveBook(&book)
        var chapters: [Chapter] = []
        for index in 0..<chapterCount {
            var chapter = Chapter(
                bookId: book.id!, index: index, title: "Chapter \(index)",
                contentHTML: "<p>Alpha beta gamma</p>", contentText: "[1] Alpha beta gamma"
            )
            try database.saveChapter(&chapter)
            chapters.append(chapter)
        }
        appState.currentBook = book
        appState.currentChapterIndex = 0
        appState.settings.readingMode = .pages
        appState.settings.pageLayout = .single
        appState.settings.rsvpEnabled = false
        appState.settings.autoAIProcessingEnabled = false
        appState.settings.autoSwitchToQuiz = false
        appState.settings.inlineAIImages = false
        session.setup(with: appState)
        session.chapters = chapters
        return chapters
    }

    private func measuredPageContext(chapter: Chapter, index: Int, count: Int) -> ScrollContext {
        let root = LibraryPaths.publicationDirectory(for: chapter.bookId)
        let state = BookContentViewState(
            document: .init(chapterId: chapter.id, chapterIndex: chapter.index,
                            contentHTML: chapter.contentHTML, baseHref: root.absoluteString),
            style: .init(
                themeBase: "#191724", themeSurface: "#1f1d2e", themeText: "#e0def4",
                themeMuted: "#6e6a86", themeRose: "#ebbcba", themeIris: "#c4a7e7",
                fontFamily: appState.settings.fontFamily, fontSize: Double(appState.settings.fontSize),
                lineSpacing: Double(appState.settings.lineSpacing)
            ),
            decorations: .init(
                annotations: session.annotations, images: session.images,
                inlineAIImagesEnabled: appState.settings.inlineAIImages,
                pendingMarkers: [], pendingImageMarkers: []
            ),
            readingMode: .pages, pageLayout: appState.settings.pageLayout
        )
        var context = pageContext(index: index, count: count)
        context.viewportWidth = 900
        context.paginationMeasurement = .init(
            state: state, viewportWidth: 900, viewportHeight: 600, pageCount: count
        )
        return context
    }

    private func configurePages(chapterCount: Int = 2) -> Chapter {
        appState.settings.readingMode = .pages
        appState.settings.rsvpEnabled = false
        appState.settings.autoSwitchToQuiz = true
        appState.settings.autoAIProcessingEnabled = false
        appState.currentBook = Book(title: "Book", author: "Author", epubPath: "", chapterCount: chapterCount)
        appState.currentChapterIndex = 0
        session.setup(with: appState)
        session.chapters = (0..<chapterCount).map {
            Chapter(id: Int64($0 + 1), bookId: 1, index: $0, title: "Chapter", contentHTML: "<p>Text</p>")
        }
        let chapter = session.chapters[0]
        session.currentChapter = chapter
        return chapter
    }

    private func pageContext(
        index: Int, count: Int, blockOffset: Double = 0, primaryType: String? = nil,
        isProgrammatic: Bool = false, visibleAnnotationIds: Set<Int64> = [], visibleImageIds: Set<Int64> = []
    ) -> ScrollContext {
        ScrollContext(
            annotationId: nil, imageId: nil, footnoteRefId: nil, blockId: 1,
            blockOffset: blockOffset, primaryType: primaryType,
            scrollPercent: count > 1 ? Double(index) / Double(count - 1) : 1,
            scrollOffset: Double(index * 600), viewportHeight: 600,
            scrollHeight: Double(count * 600), isProgrammatic: isProgrammatic,
            pageIndex: index, pageCount: count,
            visibleAnnotationIds: visibleAnnotationIds, visibleImageIds: visibleImageIds
        )
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
