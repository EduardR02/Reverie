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
}
