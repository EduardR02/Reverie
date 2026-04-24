import XCTest
import GRDB
@testable import Reverie

final class DatabaseServiceTests: XCTestCase {
    var db: DatabaseService!

    override func setUp() {
        super.setUp()
        // Use in-memory database for fast, clean tests
        let queue = try! DatabaseQueue()
        db = try! DatabaseService(dbQueue: queue)
    }

    func testBookCascadeDelete() throws {
        var book = Book(title: "Test Book", author: "Author", epubPath: "/tmp/test.epub")
        try db.saveBook(&book)
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C1", contentHTML: "p1")
        try db.saveChapter(&chapter)
        
        var annotation = Annotation(chapterId: chapter.id!, type: .science, title: "A1", content: "C1", sourceBlockId: 1)
        try db.saveAnnotation(&annotation)
        
        // Verify existence
        XCTAssertEqual(try db.fetchAllBooks().count, 1)
        XCTAssertEqual(try db.fetchChapters(for: book).count, 1)
        
        // Delete book
        try db.deleteBook(book)
        
        // Verify cascade
        XCTAssertEqual(try db.fetchAllBooks().count, 0)
    }

    func testAnnotationRefinedSearchQuery() throws {
        var book = Book(title: "T", author: "A", epubPath: "P")
        try db.saveBook(&book)
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C", contentHTML: "H")
        try db.saveChapter(&chapter)
        
        var annotation = Annotation(chapterId: chapter.id!, type: .science, title: "T", content: "C", sourceBlockId: 1)
        try db.saveAnnotation(&annotation)
        
        annotation.refinedSearchQuery = "Refined Query"
        try db.saveAnnotation(&annotation)
        
        let fetched = try db.fetchAnnotations(for: chapter)
        XCTAssertEqual(fetched.first?.refinedSearchQuery, "Refined Query")
    }

    func testBookNeedsClassificationLogic() {
        var book = Book(title: "Test", author: "A", epubPath: "P")
        
        book.classificationStatus = .pending
        XCTAssertTrue(book.needsClassification)
        
        book.classificationStatus = .inProgress
        XCTAssertTrue(book.needsClassification, "Should be true to allow recovery if the app crashed during classification")
        
        book.classificationStatus = .completed
        XCTAssertFalse(book.needsClassification)
        
        book.classificationStatus = .failed
        XCTAssertTrue(book.needsClassification, "Should retry if failed")
    }

    func testQuizQualityFeedback() throws {
        var book = Book(title: "T", author: "A", epubPath: "P")
        try db.saveBook(&book)
        
        var chapter = Chapter(bookId: book.id!, index: 0, title: "C", contentHTML: "H")
        try db.saveChapter(&chapter)
        
        var quiz = Quiz(chapterId: chapter.id!, question: "Q", answer: "A", sourceBlockId: 1)
        try db.saveQuiz(&quiz)
        
        quiz.qualityFeedback = .good
        try db.saveQuiz(&quiz)
        
        let fetched = try db.fetchQuizzes(for: chapter)
        XCTAssertEqual(fetched.first?.qualityFeedback, .good)
        
        quiz.qualityFeedback = .garbage
        try db.saveQuiz(&quiz)
        
        let fetched2 = try db.fetchQuizzes(for: chapter)
        XCTAssertEqual(fetched2.first?.qualityFeedback, .garbage)
    }

    func testQuizQualityFeedbackClears() throws {
        var book = Book(title: "T", author: "A", epubPath: "P")
        try db.saveBook(&book)

        var chapter = Chapter(bookId: book.id!, index: 0, title: "C", contentHTML: "H")
        try db.saveChapter(&chapter)

        var quiz = Quiz(chapterId: chapter.id!, question: "Q", answer: "A", sourceBlockId: 1)
        try db.saveQuiz(&quiz)

        quiz.qualityFeedback = .good
        try db.saveQuiz(&quiz)

        quiz.qualityFeedback = nil
        try db.saveQuiz(&quiz)

        let fetched = try db.fetchQuizzes(for: chapter)
        XCTAssertNil(fetched.first?.qualityFeedback)
    }

    func testGeneratedImageStatusPersists() throws {
        var book = Book(title: "T", author: "A", epubPath: "P")
        try db.saveBook(&book)

        var chapter = Chapter(bookId: book.id!, index: 0, title: "C", contentHTML: "H")
        try db.saveChapter(&chapter)

        var image = GeneratedImage(
            chapterId: chapter.id!,
            prompt: "Prompt",
            imagePath: "",
            sourceBlockId: 1,
            status: .refused,
            failureReason: "Blocked by policy"
        )
        try db.saveImage(&image)

        let fetched = try db.fetchImages(for: chapter)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].status, .refused)
        XCTAssertEqual(fetched[0].failureReason, "Blocked by policy")
        XCTAssertEqual(fetched[0].excerpt, "Prompt")
    }

    func testGeneratedImageDecodesWithoutStatusAsSuccess() throws {
        let json = """
        {
          "id": 1,
          "chapterId": 2,
          "prompt": "Prompt",
          "imagePath": "/tmp/test.png",
          "sourceBlockId": 3,
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let image = try decoder.decode(GeneratedImage.self, from: Data(json.utf8))

        XCTAssertEqual(image.status, .success)
        XCTAssertNil(image.failureReason)
        XCTAssertEqual(image.excerpt, "Prompt")
    }

    func testLLMCallUsageLedgerPersists() throws {
        var usage = LLMCallUsage(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: LLMProvider.google.rawValue,
            model: SupportedModels.Google.gemini3FlashPreview,
            task: "chat",
            inputTokens: 1_000,
            outputTokens: 200,
            reasoningTokens: 50,
            cachedTokens: 100,
            cost: 0.001
        )

        try db.saveLLMCallUsage(&usage)

        let rows = try db.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].id)
        XCTAssertEqual(rows[0].dateKey, ReadingStats.dateKey(for: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(rows[0].provider, LLMProvider.google.rawValue)
        XCTAssertEqual(rows[0].model, SupportedModels.Google.gemini3FlashPreview)
        XCTAssertEqual(rows[0].task, "chat")
        XCTAssertEqual(rows[0].inputTokens, 1_000)
        XCTAssertEqual(rows[0].outputTokens, 200)
        XCTAssertEqual(rows[0].reasoningTokens, 50)
        XCTAssertEqual(rows[0].cachedTokens, 100)
        XCTAssertEqual(rows[0].cost ?? 0, 0.001, accuracy: 0.000001)
    }

    func testImageCallUsageCostUsesEstimatedPromptInputAndImagePricing() throws {
        try db.saveImageGenerationUsage(model: .gemini25Flash)

        let rows = try db.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, LLMProvider.google.rawValue)
        XCTAssertEqual(rows[0].model, ImageModel.gemini25Flash.apiModel)
        XCTAssertEqual(rows[0].task, "image")
        XCTAssertEqual(rows[0].inputTokens, CostEstimates.imagePromptTokensPerImage)
        XCTAssertEqual(rows[0].outputTokens, 0)
        XCTAssertEqual(rows[0].cost ?? 0, 0.03906, accuracy: 0.000001)
    }

    func testMigrationToLLMCallUsagePreservesExistingData() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseService.makeMigrator()
        try migrator.migrate(queue, upTo: "v4_image_aspect_ratio")

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO books (
                    title, author, epubPath, progressPercent, currentChapter,
                    currentScrollPercent, currentScrollOffset, chapterCount, importStatus,
                    processedFully, createdAt, classificationStatus, isFinished
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "Legacy Book", "Author", "/tmp/book.epub", 0.25, 2,
                    0.5, 128.0, 10, "complete", true, createdAt,
                    ClassificationStatus.completed.rawValue, false
                ]
            )
        }

        _ = try DatabaseService(dbQueue: queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("llm_call_usage"))
            let bookCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM books WHERE title = ?", arguments: ["Legacy Book"])
            XCTAssertEqual(bookCount, 1)
            let statsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lifetime_stats WHERE id = 1")
            XCTAssertEqual(statsCount, 1)
        }
    }
}
