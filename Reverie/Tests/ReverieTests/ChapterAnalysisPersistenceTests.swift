import XCTest
import GRDB
@testable import Reverie

final class ChapterAnalysisPersistenceTests: XCTestCase {
    @MainActor
    func testChapterCommitFailureRollsBackInsightsAndQuizzes() throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        var book = Book(title: "Book", author: "Author", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Gravity curves spacetime.</p>")
        try database.saveChapter(&chapter)
        try queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_analysis_commit BEFORE UPDATE OF processed ON chapters BEGIN SELECT RAISE(ABORT, 'forced chapter commit failure'); END")
        }
        chapter.processed = true
        chapter.summary = "Gravity is discussed."
        let analysis = LLMService.ChapterAnalysis(
            annotations: [.init(type: "science", title: "Curvature", content: "Einstein described gravity geometrically.", sourceBlockId: 1)],
            quizQuestions: [.init(question: "Why do paths bend?", answer: "Spacetime is curved.", sourceBlockId: 1)],
            summary: chapter.summary!
        )

        XCTAssertThrowsError(try database.saveChapterAnalysis(analysis, chapter: &chapter, blockCount: 1))

        XCTAssertTrue(try database.fetchAnnotations(for: chapter).isEmpty)
        XCTAssertTrue(try database.fetchQuizzes(for: chapter).isEmpty)
        let persisted = try XCTUnwrap(database.fetchChapters(for: book).first)
        XCTAssertFalse(persisted.processed)
        XCTAssertNil(persisted.summary)
    }

    @MainActor
    func testAnalysisCommitPreservesReaderAndClassificationUpdates() throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        var book = Book(title: "Book", author: "Author", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Gravity curves spacetime.</p>")
        try database.saveChapter(&chapter)
        try queue.write { db in
            try db.execute(sql: "UPDATE chapters SET maxScrollReached = 0.8, userOverride = 1, isGarbage = 1 WHERE id = ?", arguments: [chapter.id!])
        }
        chapter.processed = true
        chapter.summary = "Gravity is discussed."
        chapter.rollingSummary = "A preceding event."
        chapter.contentText = "[1] Gravity curves spacetime."
        chapter.blockCount = 1
        let analysis = LLMService.ChapterAnalysis(
            annotations: [.init(type: "science", title: "Curvature", content: "Einstein described gravity geometrically.", sourceBlockId: 1)],
            summary: chapter.summary!
        )

        let saved = try database.saveChapterAnalysis(analysis, chapter: &chapter, blockCount: 1)

        let persisted = try XCTUnwrap(database.fetchChapters(for: book).first)
        XCTAssertTrue(persisted.processed)
        XCTAssertEqual(persisted.summary, "Gravity is discussed.")
        XCTAssertEqual(persisted.rollingSummary, "A preceding event.")
        XCTAssertEqual(persisted.contentText, "[1] Gravity curves spacetime.")
        XCTAssertEqual(persisted.maxScrollReached, 0.8)
        XCTAssertTrue(persisted.userOverride)
        XCTAssertTrue(persisted.isGarbage)
        XCTAssertEqual(saved.annotations.first?.id, try database.fetchAnnotations(for: chapter).first?.id)
        XCTAssertNotNil(saved.annotations.first?.id)
    }

    func testAdditionalInsightFailureDoesNotSaveEarlierRows() throws {
        let queue = try DatabaseQueue()
        let database = try DatabaseService(dbQueue: queue)
        var book = Book(title: "Book", author: "Author", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Text.</p>")
        try database.saveChapter(&chapter)
        try queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_second_insight BEFORE INSERT ON annotations WHEN NEW.title = 'Reject' BEGIN SELECT RAISE(ABORT, 'forced insight failure'); END")
        }
        var annotations = [
            Annotation(chapterId: chapter.id!, type: .science, title: "Keep", content: "First insight.", sourceBlockId: 1),
            Annotation(chapterId: chapter.id!, type: .science, title: "Reject", content: "Second insight.", sourceBlockId: 1)
        ]

        XCTAssertThrowsError(try database.saveAnnotations(&annotations))
        XCTAssertTrue(try database.fetchAnnotations(for: chapter).isEmpty)
    }
}
