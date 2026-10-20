import XCTest
import GRDB
@testable import Reverie

@MainActor
final class PendingProgressRegressionTests: XCTestCase {
    private func fixture() throws -> (DatabaseService, Book, [Chapter]) {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        var book = Book(title: "Progress regression", author: "Author", epubPath: "/tmp/progress.epub")
        book.chapterCount = 2
        try database.saveBook(&book)
        let bookId = try XCTUnwrap(book.id)
        var chapters: [Chapter] = []
        for index in 0..<2 {
            var chapter = Chapter(
                bookId: bookId, index: index, title: "Chapter \(index + 1)",
                contentHTML: "<p>Original content.</p>", wordCount: 1_000
            )
            try database.saveChapter(&chapter)
            chapters.append(chapter)
        }
        return (database, book, chapters)
    }

    private func record(_ tracker: ProgressTracker, chapter: Chapter, percent: Double, book: Book) throws {
        tracker.recordReadingProgress(
            chapter: chapter, currentPercent: percent, furthestPercent: percent,
            scrollOffset: percent * 1_000, bookId: try XCTUnwrap(book.id), whenReadyToFlush: {}
        )
    }

    func testBacktrackingBeforeFlushKeepsHighestReadingPosition() throws {
        let (database, book, chapters) = try fixture()
        var creditedWords = 0
        let tracker = ProgressTracker(database: database, onWordsRead: { creditedWords += $0 })
        tracker.updateBookProgressCache(book: book, chapters: chapters)
        try record(tracker, chapter: chapters[0], percent: 0.8, book: book)
        try record(tracker, chapter: chapters[0], percent: 0.2, book: book)
        let savedBook = try XCTUnwrap(tracker.flushPendingProgress(currentBook: book))
        let savedChapter = try XCTUnwrap(database.fetchChapters(for: book).first)
        XCTAssertEqual(savedChapter.maxScrollReached, 0.8)
        XCTAssertEqual(creditedWords, 800)
        XCTAssertEqual(savedBook.currentScrollPercent, 0.2)
        XCTAssertEqual(savedBook.progressPercent, 0.4)
    }

    func testFastChapterSwitchFlushesThePreviousChapter() throws {
        let (database, book, chapters) = try fixture()
        var creditedWords = 0
        let tracker = ProgressTracker(database: database, onWordsRead: { creditedWords += $0 })
        tracker.updateBookProgressCache(book: book, chapters: chapters)
        try record(tracker, chapter: chapters[0], percent: 0.9, book: book)
        try record(tracker, chapter: chapters[1], percent: 0.1, book: book)
        let savedBook = try XCTUnwrap(tracker.flushPendingProgress(currentBook: book))
        let savedChapters = try database.fetchChapters(for: book)
        XCTAssertEqual(savedChapters.map(\.maxScrollReached), [0.9, 0.1])
        XCTAssertEqual(creditedWords, 1_000)
        XCTAssertEqual(savedBook.currentChapter, 1)
        XCTAssertEqual(savedBook.progressPercent, 0.5)
    }

    func testRebuildingCacheFromStaleChapterSnapshotsDoesNotResetProgress() throws {
        let (database, book, chapters) = try fixture()
        let tracker = ProgressTracker(database: database)
        tracker.updateBookProgressCache(book: book, chapters: chapters)
        try record(tracker, chapter: chapters[0], percent: 0.8, book: book)
        let firstSave = tracker.flushPendingProgress(currentBook: book)
        tracker.updateBookProgressCache(book: book, chapters: chapters)
        try record(tracker, chapter: chapters[0], percent: 0.2, book: book)
        let savedBook = try XCTUnwrap(tracker.flushPendingProgress(currentBook: firstSave))
        XCTAssertEqual(savedBook.progressPercent, 0.4)
    }

    func testSavingProgressDoesNotOverwriteNewerChapterContent() throws {
        let (database, book, chapters) = try fixture()
        let tracker = ProgressTracker(database: database)
        try record(tracker, chapter: chapters[0], percent: 0.5, book: book)
        var newerChapter = chapters[0]
        newerChapter.contentHTML = "<p>Newly processed content.</p>"
        newerChapter.wordCount = 2_000
        try database.saveChapter(&newerChapter)
        _ = tracker.flushPendingProgress(currentBook: book)
        let savedChapter = try XCTUnwrap(database.fetchChapters(for: book).first)
        XCTAssertEqual(savedChapter.contentHTML, newerChapter.contentHTML)
        XCTAssertEqual(savedChapter.wordCount, newerChapter.wordCount)
        XCTAssertEqual(savedChapter.maxScrollReached, 0.5)
    }
}
