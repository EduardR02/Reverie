import XCTest
import GRDB
@testable import Reverie

@MainActor
final class SemanticReadingPositionTests: XCTestCase {
    func testMigrationKeepsLegacyPixelPositionWithoutInventingAnAnchor() throws {
        let queue = try DatabaseQueue()
        try DatabaseService.makeMigrator().migrate(queue, upTo: "v6_cached_input_stats")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO books (title, author, epubPath, chapterCount, currentChapter,
                    currentScrollPercent, currentScrollOffset, progressPercent, createdAt, classificationStatus)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["Existing book", "Author", "/tmp/existing.epub", 8, 3,
                    0.47, 8_723.5, 0.74, Date(timeIntervalSince1970: 1_700_000_000), "completed"])
        }
        let database = try DatabaseService(dbQueue: queue)
        let restored = try XCTUnwrap(database.fetchAllBooks().first)
        XCTAssertEqual(restored.currentChapter, 3)
        XCTAssertEqual(restored.currentScrollPercent, 0.47)
        XCTAssertEqual(restored.currentScrollOffset, 8_723.5)
        XCTAssertEqual(restored.progressPercent, 0.74)
        XCTAssertNil(restored.currentBlockId)
        XCTAssertNil(restored.currentBlockOffset)
    }

    func testCoalescedBacktrackingSavesCurrentTextAnchorWithoutLosingFurthestProgress() throws {
        let (database, book, chapters) = try fixture()
        let state = AppState(database: database, settings: UserSettings())
        state.openBook(book)
        state.recordReadingProgress(chapter: chapters[0], currentPercent: 0.8, furthestPercent: 0.8,
            scrollOffset: 4_800, location: BlockLocation(blockId: 18, offset: 0.75))
        state.recordReadingProgress(chapter: chapters[0], currentPercent: 0.2, furthestPercent: 0.2,
            scrollOffset: 1_200, location: BlockLocation(blockId: 4, offset: 0.3))
        state.flushPendingProgress()
        let restored = try XCTUnwrap(database.fetchBook(id: XCTUnwrap(book.id)))
        XCTAssertEqual(restored.currentBlockId, 4)
        XCTAssertEqual(restored.currentBlockOffset, 0.3)
        XCTAssertEqual(restored.currentScrollOffset, 1_200)
        XCTAssertEqual(restored.currentScrollPercent, 0.2)
        XCTAssertEqual(try database.fetchChapters(for: book)[0].maxScrollReached, 0.8)
    }

    func testChapterTransitionWithoutPositionClearsThePreviousChapterAnchor() throws {
        let (database, book, chapters) = try fixture()
        let state = AppState(database: database, settings: UserSettings())
        state.openBook(book)
        state.recordReadingProgress(chapter: chapters[0], currentPercent: 0.7, furthestPercent: 0.7,
            scrollOffset: 4_200, location: BlockLocation(blockId: 15, offset: 0.8))
        state.flushPendingProgress()
        state.recordReadingProgress(chapter: chapters[1], currentPercent: 0, furthestPercent: 0, scrollOffset: 0)
        state.flushPendingProgress()
        let restored = try XCTUnwrap(database.fetchBook(id: XCTUnwrap(book.id)))
        XCTAssertEqual(restored.currentChapter, 1)
        XCTAssertNil(restored.currentBlockId)
        XCTAssertNil(restored.currentBlockOffset)
        XCTAssertEqual(restored.currentScrollOffset, 0)
        XCTAssertEqual(try database.fetchChapters(for: book)[0].maxScrollReached, 0.7)
    }

    func testSwitchingBooksFlushesTheirIndependentSemanticAnchors() throws {
        let (database, firstBook, firstChapters) = try fixture()
        var secondBook = Book(title: "Second book", author: "Author", epubPath: "/tmp/second.epub", chapterCount: 1)
        try database.saveBook(&secondBook)
        var secondChapter = Chapter(bookId: try XCTUnwrap(secondBook.id), index: 0,
            title: "Second chapter", contentHTML: "<p>Other text.</p>", wordCount: 200)
        try database.saveChapter(&secondChapter)
        let state = AppState(database: database, settings: UserSettings())
        state.openBook(firstBook)
        state.recordReadingProgress(chapter: firstChapters[0], currentPercent: 0.6, furthestPercent: 0.6,
            scrollOffset: 3_600, location: BlockLocation(blockId: 12, offset: 0.25))
        state.openBook(secondBook)
        state.recordReadingProgress(chapter: secondChapter, currentPercent: 0.1, furthestPercent: 0.1,
            scrollOffset: 100, location: BlockLocation(blockId: 2, offset: 0.5))
        state.closeBook()
        let first = try XCTUnwrap(database.fetchBook(id: XCTUnwrap(firstBook.id)))
        let second = try XCTUnwrap(database.fetchBook(id: XCTUnwrap(secondBook.id)))
        XCTAssertEqual(first.currentBlockId, 12)
        XCTAssertEqual(first.currentBlockOffset, 0.25)
        XCTAssertEqual(second.currentBlockId, 2)
        XCTAssertEqual(second.currentBlockOffset, 0.5)
    }

    private func fixture() throws -> (DatabaseService, Book, [Chapter]) {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        var book = Book(title: "Position fixture", author: "Author", epubPath: "/tmp/position.epub", chapterCount: 2)
        try database.saveBook(&book)
        var chapters: [Chapter] = []
        for index in 0..<2 {
            var chapter = Chapter(bookId: try XCTUnwrap(book.id), index: index,
                title: "Chapter \(index + 1)", contentHTML: "<p>Text.</p>", wordCount: 1_000)
            try database.saveChapter(&chapter)
            chapters.append(chapter)
        }
        return (database, book, chapters)
    }
}
