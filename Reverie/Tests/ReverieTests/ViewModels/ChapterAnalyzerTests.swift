import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ChapterAnalyzerTests: XCTestCase {
    var analyzer: ChapterAnalyzer!
    var llmService: LLMService!
    var imageService: ImageService!
    var database: DatabaseService!
    var settings: UserSettings!
    var mockSession: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        settings = UserSettings()
        settings.googleAPIKey = "mock-key"
        
        llmService = LLMService(session: mockSession)
        imageService = ImageService(session: mockSession)
        
        let queue = try! DatabaseQueue()
        database = try! DatabaseService(dbQueue: queue)
        
        analyzer = ChapterAnalyzer(
            llm: llmService,
            imageService: imageService,
            database: database,
            settings: settings
        )
    }

    var runningTasks: [Task<Void, any Error>] = []

    override func tearDown() async throws {
        for task in runningTasks {
            task.cancel()
        }
        
        // Wait for tasks to actually finish to avoid leaking requests into other tests
        for task in runningTasks {
            _ = try? await task.value
        }
        runningTasks.removeAll()
        
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    func test_analyzeChapter_setsProcessingState() async {
        // Given
        var book = Book(title: "Book 1", author: "Author 1", epubPath: "")
        try? database.saveBook(&book)
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter 1", contentHTML: "<p>Content</p>")
        try? database.saveChapter(&chapter)
        let chapterId = chapter.id!
        
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 0.2)
            let response = HTTPURLResponse(url: URL(string: "https://api.example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        
        // When
        let stream = analyzer.analyzeChapter(chapter, book: book)
        
        let task = Task {
            for try await _ in stream {}
        }
        runningTasks.append(task)
        
        // Give it a moment to enter the processing block
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Then
        XCTAssertTrue(analyzer.processingStates[chapterId]?.isProcessingInsights ?? false)
    }

    func test_cancel_clearsProcessingState() async {
        // Given
        var book = Book(title: "Book 1", author: "Author 1", epubPath: "")
        try? database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter 1", contentHTML: "<p>Content</p>")
        try? database.saveChapter(&chapter)
        let chapterId = chapter.id!
        
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return (HTTPURLResponse(), Data())
        }
        
        let stream = analyzer.analyzeChapter(chapter, book: book)
        let task = Task { for try await _ in stream {} }
        runningTasks.append(task)
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(analyzer.processingStates[chapterId]?.isProcessingInsights ?? false)
        
        // When
        analyzer.cancel()
        task.cancel()
        
        // Then
        XCTAssertFalse(analyzer.processingStates[chapterId]?.isProcessingInsights ?? true)
    }

    func test_classifyChapters_setsIsClassifying() async {
        // Given
        var book = Book(title: "Book 1", author: "Author 1", epubPath: "")
        try? database.saveBook(&book)
        
        let chapters = [Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1")]
        
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 0.2)
            let response = HTTPURLResponse(url: URL(string: "https://api.example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{\"classifications\": []}".data(using: .utf8)!)
        }
        
        // When
        let task = Task {
            _ = try await analyzer.classifyChapters(chapters, for: book)
        }
        runningTasks.append(task)
        
        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Then
        XCTAssertTrue(analyzer.isClassifying)
    }

    func test_shouldAutoProcess_returnsFalseForGarbageChapter() {
        // Given
        var localSettings = UserSettings()
        localSettings.autoAIProcessingEnabled = true
        localSettings.googleAPIKey = "key"
        
        let localAnalyzer = ChapterAnalyzer(llm: llmService, imageService: imageService, database: database, settings: localSettings)
        
        let chapter = Chapter(id: 1, bookId: 1, index: 0, title: "C", contentHTML: "H", isGarbage: true)
        
        // When
        let result = localAnalyzer.shouldAutoProcess(chapter, in: [chapter])
        
        // Then
        XCTAssertFalse(result)
    }

    func test_shouldAutoProcess_returnsTrueForContentChapter() {
        // Given
        var localSettings = UserSettings()
        localSettings.autoAIProcessingEnabled = true
        localSettings.googleAPIKey = "key"
        
        let localAnalyzer = ChapterAnalyzer(llm: llmService, imageService: imageService, database: database, settings: localSettings)
        
        let chapter = Chapter(id: 1, bookId: 1, index: 0, title: "C", contentHTML: "H", isGarbage: false)
        
        // When
        let result = localAnalyzer.shouldAutoProcess(chapter, in: [chapter])
        
        // Then
        XCTAssertTrue(result)
    }

    func test_shouldAutoProcess_requiresClassificationComplete() {
        // Given
        var settings = UserSettings()
        settings.autoAIProcessingEnabled = true
        settings.googleAPIKey = "key"
        let analyzer = ChapterAnalyzer(llm: llmService, imageService: imageService, database: database, settings: settings)
        
        let chapter = Chapter(id: 1, bookId: 1, index: 0, title: "C", contentHTML: "H", isGarbage: false)
        let chapters = [chapter]
        
        // When & Then
        var book = Book(title: "B", author: "A", epubPath: "")
        
        book.classificationStatus = .pending
        XCTAssertFalse(analyzer.shouldAutoProcess(chapter, in: chapters, book: book))
        
        book.classificationStatus = .inProgress
        XCTAssertFalse(analyzer.shouldAutoProcess(chapter, in: chapters, book: book))
        
        book.classificationStatus = .failed
        XCTAssertFalse(analyzer.shouldAutoProcess(chapter, in: chapters, book: book))
        
        book.classificationStatus = .completed
        XCTAssertTrue(analyzer.shouldAutoProcess(chapter, in: chapters, book: book))
    }

    func test_shouldAutoProcess_respectsAllConditions() {
        // Test matrix of: autoAIProcessingEnabled, hasLLMKey, isGarbage, processed, classificationStatus
        
        func check(autoAI: Bool, hasKey: Bool, isGarbage: Bool, processed: Bool, status: ClassificationStatus) -> Bool {
            var localSettings = UserSettings()
            localSettings.autoAIProcessingEnabled = autoAI
            localSettings.googleAPIKey = hasKey ? "key" : ""
            
            let localAnalyzer = ChapterAnalyzer(
                llm: llmService,
                imageService: imageService,
                database: database,
                settings: localSettings
            )
            
            let chapter = Chapter(id: 1, bookId: 1, index: 0, title: "C", contentHTML: "H", processed: processed, isGarbage: isGarbage)
            let book = Book(title: "B", author: "A", epubPath: "", classificationStatus: status)
            return localAnalyzer.shouldAutoProcess(chapter, in: [chapter], book: book)
        }
        
        // All true/correct -> True
        XCTAssertTrue(check(autoAI: true, hasKey: true, isGarbage: false, processed: false, status: .completed))
        
        // One false -> False
        XCTAssertFalse(check(autoAI: false, hasKey: true, isGarbage: false, processed: false, status: .completed))
        XCTAssertFalse(check(autoAI: true, hasKey: false, isGarbage: false, processed: false, status: .completed))
        XCTAssertFalse(check(autoAI: true, hasKey: true, isGarbage: true, processed: false, status: .completed))
        XCTAssertFalse(check(autoAI: true, hasKey: true, isGarbage: false, processed: true, status: .completed))
        XCTAssertFalse(check(autoAI: true, hasKey: true, isGarbage: false, processed: false, status: .pending))
    }

    func test_generateImages_persistsWrappedPromptInsteadOfExcerpt() async throws {
        var book = Book(title: "Book 1", author: "Author 1", epubPath: "")
        try database.saveBook(&book)

        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter 1", contentHTML: "<p>Content</p>")
        try database.saveChapter(&chapter)

        let excerpt = "A narrow alley at dusk"
        let expectedPrompt = llmService.imagePromptFromExcerpt(excerpt, rewrite: settings.rewriteImageExcerpts)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":{"message":"blocked by policy","code":400}}"#.data(using: .utf8)!
            return (response, data)
        }

        var generated: [GeneratedImage] = []
        let stream = analyzer.generateImages(
            suggestions: [.init(excerpt: excerpt, sourceBlockId: 1)],
            book: book,
            chapter: chapter
        )
        for try await image in stream {
            generated.append(image)
        }

        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(generated[0].excerpt, excerpt)
        XCTAssertEqual(generated[0].prompt, expectedPrompt)

        let persisted = try database.fetchImages(for: chapter)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].excerpt, excerpt)
        XCTAssertEqual(persisted[0].prompt, expectedPrompt)
    }

    func test_retryImage_usesStoredPromptForGenerationRequest() async throws {
        var book = Book(title: "Book 1", author: "Author 1", epubPath: "")
        try database.saveBook(&book)

        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter 1", contentHTML: "<p>Content</p>")
        try database.saveChapter(&chapter)

        let storedPrompt = "FULL_WRAPPED_IMAGE_PROMPT"
        var failedImage = GeneratedImage(
            chapterId: chapter.id!,
            excerpt: "Short excerpt",
            prompt: storedPrompt,
            imagePath: "",
            sourceBlockId: 1,
            status: .failed,
            failureReason: "Old failure"
        )
        try database.saveImage(&failedImage)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":{"message":"retry still blocked","code":400}}"#.data(using: .utf8)!
            return (response, data)
        }

        let updated = try await analyzer.retryImage(failedImage, book: book, chapter: chapter)

        XCTAssertEqual(updated.excerpt, "Short excerpt")
        XCTAssertEqual(updated.prompt, storedPrompt)

        let persisted = try database.fetchImages(for: chapter)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].excerpt, "Short excerpt")
        XCTAssertEqual(persisted[0].prompt, storedPrompt)
    }
}
