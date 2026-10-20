import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ReaderAIPauseTests: XCTestCase {
    private var session: ReaderSession!
    private var appState: AppState!
    private var database: DatabaseService!
    private var transport: URLSession!
    private var requests: ReaderAIRequestGate!
    private var savedUserSettings: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedUserSettings = UserDefaults.standard.data(forKey: "userSettings")
        database = try DatabaseService(dbQueue: DatabaseQueue())
        appState = AppState(database: database)
        appState.settings = UserSettings()
        appState.settings.googleAPIKey = "reader-pause-test-key"
        requests = ReaderAIRequestGate()
        ReaderAIPauseURLProtocol.gate = requests
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderAIPauseURLProtocol.self]
        transport = URLSession(configuration: configuration)
        appState.llmService = LLMService(appState: appState, session: transport)
        appState.imageService = ImageService(session: transport)
        session = ReaderSession()
    }

    override func tearDown() async throws {
        session.cleanup()
        transport.invalidateAndCancel()
        requests.reset()
        if let savedUserSettings {
            UserDefaults.standard.set(savedUserSettings, forKey: "userSettings")
        } else {
            UserDefaults.standard.removeObject(forKey: "userSettings")
        }
        try await super.tearDown()
    }

    func testHiddenReaderLoadsChaptersButRejectsBackgroundAndPanelAIEntries() async throws {
        let chapters = try storeBook(classification: .pending, chapterCount: 2)
        appState.settings.imagesEnabled = true
        session.setup(with: appState)
        session.setAIPanelVisible(false)
        await session.loadChapters()
        session.processCurrentChapter(force: true)
        session.forceProcessGarbageChapter()
        session.retryClassification()
        session.generateMoreInsights()
        session.generateMoreQuestions()
        let failedImage = GeneratedImage(chapterId: chapters[0].id!, prompt: "A river", imagePath: "", sourceBlockId: 1, status: .failed)
        await session.retryImage(failedImage)
        await session.rewriteAndRetryImage(failedImage)
        appState.currentChapterIndex = 1
        await session.loadChapter(at: 1)
        session.processCurrentChapter()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(session.isAIPanelVisible)
        XCTAssertEqual(session.currentChapter?.id, chapters[1].id)
        XCTAssertFalse(session.isLoadingChapters)
        XCTAssertEqual(requests.count, 0)
        XCTAssertFalse(session.analyzer?.isClassifying ?? true)
        XCTAssertFalse(session.currentChapter?.userOverride ?? true)
    }

    func testHideCancelsActiveAnalysisAndReleasesChatFocusAndPause() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        session.setup(with: appState)
        await session.loadChapters()
        await waitUntil { self.requests.count == 1 }
        XCTAssertTrue(session.analyzer?.processingStates[chapter.id!]?.isProcessingInsights ?? false)
        session.aiPanelSelectedTab = .chat
        session.handleTabChange(from: .insights, to: .chat)
        session.isChatInputFocused = true
        session.pendingChatPrompt = "Explain this"
        XCTAssertTrue(appState.readingSpeedTracker.activePauseReasons.contains(.chatting))

        session.setAIPanelVisible(false)

        XCTAssertFalse(session.isChatInputFocused)
        XCTAssertNil(session.pendingChatPrompt)
        XCTAssertFalse(appState.readingSpeedTracker.activePauseReasons.contains(.chatting))
        XCTAssertFalse(session.analyzer?.processingStates[chapter.id!]?.isProcessingInsights ?? true)
        XCTAssertEqual(session.analyzer?.processingStates[chapter.id!]?.liveThinking, "")
        await waitUntil { self.requests.stoppedCount == 1 }
        session.handleTabChange(from: .insights, to: .chat)
        XCTAssertFalse(appState.readingSpeedTracker.activePauseReasons.contains(.chatting))
        XCTAssertFalse(try XCTUnwrap(database.fetchChapters(for: appState.currentBook!).first).processed)
    }

    func testShowResumesUnfinishedAnalysisButNeverRepeatsCompletedContent() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        session.setup(with: appState)
        await session.loadChapters()
        await waitUntil { self.requests.count == 1 }
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        await waitUntil { self.requests.count == 2 }
        try requests.respond(to: 1, text: Self.analysisResponse)
        await waitUntil { self.session.currentChapter?.processed == true }
        XCTAssertEqual(session.annotations.count, 1)
        XCTAssertEqual(session.quizzes.count, 1)

        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        session.processCurrentChapter(force: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try database.fetchAnnotations(for: chapter).count, 1)
        XCTAssertEqual(try database.fetchQuizzes(for: chapter).count, 1)
        XCTAssertEqual(session.annotations.count, 1)
        XCTAssertEqual(session.quizzes.count, 1)
    }

    func testInterruptedManualAnalysisResumesWithAutomaticProcessingDisabled() async throws {
        _ = try storeBook()
        appState.settings.autoAIProcessingEnabled = false
        session.setup(with: appState)
        await session.loadChapters()
        session.processCurrentChapter(force: true)
        await waitUntil { self.requests.count == 1 }
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        await waitUntil { self.requests.count == 2 }
        try requests.respond(to: 1, text: Self.analysisResponse)
        await waitUntil { self.session.currentChapter?.processed == true }
        XCTAssertEqual(session.annotations.count, 1)
    }

    func testRapidHideShowCannotClearReplacementAnalysisOrItsBusyState() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        session.setup(with: appState)
        await session.loadChapters()
        await waitUntil { self.requests.count == 1 }
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        await waitUntil { self.requests.count == 2 && self.requests.stoppedCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.analyzer?.processingStates[chapter.id!]?.isProcessingInsights ?? false)
        XCTAssertNil(session.analyzer?.processingStates[chapter.id!]?.error)
        session.processCurrentChapter()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 2)

        session.setAIPanelVisible(false)
        await waitUntil { self.requests.stoppedCount == 2 }
        XCTAssertFalse(session.analyzer?.processingStates[chapter.id!]?.isProcessingInsights ?? true)
        XCTAssertTrue(try database.fetchAnnotations(for: chapter).isEmpty)
    }

    func testShowResumesClassificationWithoutOldCleanupClearingReplacementState() async throws {
        _ = try storeBook(classification: .pending)
        session.setup(with: appState)
        await session.loadChapters()
        await waitUntil { self.requests.count == 1 }
        XCTAssertTrue(session.analyzer?.isClassifying ?? false)
        session.setAIPanelVisible(false)
        XCTAssertFalse(session.analyzer?.isClassifying ?? true)
        session.setAIPanelVisible(true)
        await waitUntil { self.requests.count == 2 && self.requests.stoppedCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.analyzer?.isClassifying ?? false)
        try requests.respond(to: 1, text: #"{"classifications":[{"index":0,"type":"garbage"}]}"#)
        await waitUntil { self.appState.currentBook?.classificationStatus == .completed }
        XCTAssertTrue(session.currentChapter?.isGarbage ?? false)
        XCTAssertNil(session.analyzer?.classificationError)
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 2)
    }

    func testQueuedAIWorkDoesNotStartAfterHideAndSavedAssetsRefreshOnShow() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        appState.settings.autoAIProcessingEnabled = false
        session.setup(with: appState)
        await session.loadChapters()
        session.processCurrentChapter(force: true)
        session.generateMoreInsights()
        session.generateMoreQuestions()
        session.setAIPanelVisible(false)
        var savedChapter = chapter
        savedChapter.processed = true
        savedChapter.summary = "Already saved"
        try database.saveChapter(&savedChapter)
        var annotation = Annotation(chapterId: chapter.id!, type: .science, title: "Saved", content: "Saved while the panel was absent.", sourceBlockId: 1)
        try database.saveAnnotation(&annotation)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 0)

        session.setAIPanelVisible(true)
        XCTAssertTrue(session.currentChapter?.processed ?? false)
        XCTAssertEqual(session.annotations.map(\.id), [annotation.id])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 0)
    }

    func testHideDoesNotCancelBookOwnedBackgroundTasks() async throws {
        _ = try storeBook()
        appState.settings.autoAIProcessingEnabled = false
        session.setup(with: appState)
        await session.loadChapters()
        let bookTask = Task {
            _ = try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.trackBackgroundTask(bookTask)
        session.setAIPanelVisible(false)
        XCTAssertFalse(bookTask.isCancelled)
        session.isChatInputFocused = true
        XCTAssertFalse(session.isChatInputFocused, "Late unmounted focus callbacks must not trap reader keys")
        bookTask.cancel()
        await bookTask.value
    }

    func testCompletedManualOverrideAndMissingAuthenticationNeverRestartOnShow() async throws {
        var chapter = try XCTUnwrap(storeBook().first)
        chapter.processed = true
        chapter.userOverride = true
        try database.saveChapter(&chapter)
        session.setup(with: appState)
        await session.loadChapters()
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 0)

        chapter.processed = false
        try database.saveChapter(&chapter)
        appState.settings.googleAPIKey = ""
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        session.processCurrentChapter(force: true)
        session.retryClassification()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 0)
    }

    func testImageBatchStopsQueuedRequestsAndResumesOnlyUnfinishedImages() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        appState.settings.imagesEnabled = true
        appState.settings.maxConcurrentRequests = 1
        session.setup(with: appState)
        await session.loadChapters()
        await waitUntil { self.requests.count == 1 }
        try requests.respond(to: 0, text: #"{"summary":"Done.","annotations":[],"quizQuestions":[],"imageSuggestions":[{"excerpt":"One","sourceBlockId":1},{"excerpt":"two","sourceBlockId":1},{"excerpt":"three.","sourceBlockId":1}]}"#)
        await waitUntil { self.requests.count == 2 && self.session.currentChapter?.processed == true }
        session.setAIPanelVisible(false)
        await waitUntil { self.requests.stoppedCount >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 2, "Cancelling a batch must not enqueue its remaining provider requests")
        XCTAssertFalse(session.analyzer?.processingStates[chapter.id!]?.isProcessingImages ?? true)

        session.setAIPanelVisible(true)
        await waitUntil { self.requests.count == 3 }
        for index in 2...4 {
            try requests.respond(to: index, text: "Image generation was refused.")
            if index < 4 { await waitUntil { self.requests.count == index + 2 } }
        }
        await waitUntil { self.session.images.count == 3 }
        XCTAssertEqual(try database.fetchImages(for: chapter).count, 3)
        session.setAIPanelVisible(false)
        session.setAIPanelVisible(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(session.images.count, 3)
    }

    func testHiddenTabCyclingAndQuizTugDoNotSelectInvisibleContent() async throws {
        _ = try storeBook(chapterCount: 2)
        appState.settings.autoAIProcessingEnabled = false
        appState.settings.autoSwitchToQuiz = true
        session.setup(with: appState)
        await session.loadChapters()
        session.quizzes = [Quiz(chapterId: session.currentChapter!.id!, question: "Why?", answer: "Because", sourceBlockId: 1)]
        session.aiPanelSelectedTab = .insights
        session.setAIPanelVisible(false)
        session.cycleAIPanelTab(direction: 1)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(session.aiPanelSelectedTab, .insights)
        XCTAssertFalse(session.hasAutoSwitchedToQuiz)
    }

    func testHiddenPageTugAdvancesChapterInsteadOfOfferingInvisibleQuiz() async throws {
        let chapter = try XCTUnwrap(storeBook(chapterCount: 2).first)
        appState.settings.autoAIProcessingEnabled = false
        appState.settings.autoSwitchToQuiz = true
        appState.settings.readingMode = .pages
        session.setup(with: appState)
        await session.loadChapters()
        session.quizzes = [Quiz(chapterId: chapter.id!, question: "Why?", answer: "Because", sourceBlockId: 1)]
        var context = ScrollContext(
            annotationId: nil, imageId: nil, footnoteRefId: nil,
            blockId: 1, blockOffset: 0, primaryType: nil,
            scrollPercent: 1, scrollOffset: 0, viewportHeight: 800,
            scrollHeight: 800, isProgrammatic: false
        )
        context.pageIndex = 0
        context.pageCount = 1
        context.visiblePageCount = 1
        session.handleScrollUpdate(context: context, chapter: chapter)
        session.setAIPanelVisible(false)
        session.handleQuizAutoSwitchOnTug()
        XCTAssertEqual(appState.currentChapterIndex, 1)
        XCTAssertNotEqual(session.aiPanelSelectedTab, .quiz)
    }

    func testHiddenRSVPContentPauseContinuesWithoutOpeningPanel() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        appState.settings.autoAIProcessingEnabled = false
        session.setup(with: appState)
        await session.loadChapters()
        let annotation = Annotation(id: 20, chapterId: chapter.id!, type: .science, title: "Saved", content: "An insight", sourceBlockId: 1)
        let blocks = ContentBlockParser().parse(html: "<p>One two three</p>").blocks
        session.rsvpEngine.loadChapter(blocks: blocks, annotations: [annotation], images: [], footnotes: [])
        session.rsvpEngine.sync(toBlockId: 1)
        XCTAssertNotNil(session.rsvpEngine.pendingPauseContent)
        session.setAIPanelVisible(false)
        XCTAssertNil(session.rsvpEngine.pendingPauseContent)
        XCTAssertTrue(session.rsvpEngine.isPlaying)
        session.rsvpEngine.sync(toBlockId: 1)
        session.handleRSVPPauseContentChange(session.rsvpEngine.pendingPauseContent)
        XCTAssertNil(session.rsvpEngine.pendingPauseContent)
        XCTAssertFalse(session.isAIPanelVisible)
        session.rsvpEngine.pause()
    }

    func testExplicitBookActionsRevealPanelBeforeUsingAIOrSavedContent() async throws {
        let chapter = try XCTUnwrap(storeBook().first)
        appState.settings.autoAIProcessingEnabled = false
        appState.settings.imagesEnabled = true
        var annotation = Annotation(chapterId: chapter.id!, type: .science, title: "Saved", content: "A saved insight", sourceBlockId: 1)
        var image = GeneratedImage(chapterId: chapter.id!, prompt: "Saved", imagePath: "/tmp/saved.png", sourceBlockId: 1)
        try database.saveAnnotation(&annotation)
        try database.saveImage(&image)
        session.setup(with: appState)
        await session.loadChapters()
        session.setAIPanelVisible(false)
        session.handleAnnotationClick(annotation)
        XCTAssertTrue(session.isAIPanelVisible)
        XCTAssertEqual(session.externalTabSelection, .insights)
        session.setAIPanelVisible(false)
        session.handleImageMarkerClick(image.id!)
        XCTAssertTrue(session.isAIPanelVisible)
        XCTAssertEqual(session.externalTabSelection, .images)
        session.footnotes = [Footnote(chapterId: chapter.id!, marker: "1", content: "A note", refId: "note-1", sourceBlockId: 1)]
        session.setAIPanelVisible(false)
        session.handleFootnoteClick("note-1")
        XCTAssertTrue(session.isAIPanelVisible)
        XCTAssertEqual(session.externalTabSelection, .footnotes)
        session.setAIPanelVisible(false)
        session.handleWordClick(word: "One", context: "One two", blockId: 1, action: .explain)
        XCTAssertTrue(session.isAIPanelVisible)
        XCTAssertNotNil(session.pendingChatPrompt)
        session.setAIPanelVisible(false)
        session.handleWordClick(word: "One", context: "One two", blockId: 1, action: .generateImage)
        XCTAssertTrue(session.isAIPanelVisible)
        await waitUntil { self.requests.count == 1 }
        session.setAIPanelVisible(false)
        await waitUntil { self.requests.stoppedCount == 1 }
        XCTAssertEqual(try database.fetchImages(for: chapter).count, 1)
    }

    private func storeBook(classification: ClassificationStatus = .completed, chapterCount: Int = 1) throws -> [Chapter] {
        var book = Book(title: "Book", author: "Author", epubPath: "", chapterCount: chapterCount)
        book.importStatus = .complete
        book.classificationStatus = classification
        try database.saveBook(&book)
        appState.currentBook = book
        var chapters: [Chapter] = []
        for index in 0..<chapterCount {
            var chapter = Chapter(bookId: book.id!, index: index, title: "Chapter \(index)", contentHTML: "<p>One two three.</p>")
            try database.saveChapter(&chapter)
            chapters.append(chapter)
        }
        return chapters
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private static let analysisResponse = #"{"summary":"A completed chapter.","annotations":[{"type":"science","title":"A connection","content":"A precise scientific connection.","sourceBlockId":1}],"quizQuestions":[{"question":"What connects these ideas?","answer":"The scientific mechanism.","sourceBlockId":1}],"imageSuggestions":[]}"#
}

private final class ReaderAIRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var loaders: [ReaderAIPauseURLProtocol] = []
    private var stopped: Set<ObjectIdentifier> = []

    var count: Int { lock.withLock { loaders.count } }
    var stoppedCount: Int { lock.withLock { stopped.count } }

    func start(_ loader: ReaderAIPauseURLProtocol) {
        lock.withLock { loaders.append(loader) }
    }

    func stop(_ loader: ReaderAIPauseURLProtocol) {
        _ = lock.withLock { stopped.insert(ObjectIdentifier(loader)) }
    }

    func respond(to index: Int, text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let loader = try XCTUnwrap(lock.withLock {
            loaders.indices.contains(index) ? loaders[index] : nil
        }, "No provider request at index \(index)", file: file, line: line)
        let payload: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        loader.respond(data)
    }

    func reset() {
        lock.withLock {
            loaders.removeAll()
            stopped.removeAll()
        }
    }
}

private final class ReaderAIPauseURLProtocol: URLProtocol {
    nonisolated(unsafe) static var gate = ReaderAIRequestGate()
    private var requestGate: ReaderAIRequestGate?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        requestGate = Self.gate
        requestGate?.start(self)
    }

    override func stopLoading() {
        requestGate?.stop(self)
    }

    func respond(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
