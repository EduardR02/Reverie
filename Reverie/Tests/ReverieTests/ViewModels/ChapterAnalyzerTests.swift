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
}
