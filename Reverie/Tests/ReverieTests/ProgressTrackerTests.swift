import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ProgressTrackerTests: XCTestCase {
    var db: DatabaseService!
    var tracker: ProgressTracker!
    var wordsReadCount: Int!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let queue = try! DatabaseQueue()
        db = try! DatabaseService(dbQueue: queue)
        wordsReadCount = 0
        tracker = ProgressTracker(
            database: db,
            onWordsRead: { [weak self] in self?.wordsReadCount += $0 }
        )
    }

    // MARK: - Flushing

    func testFlushEmptyDoesNothing() {
        let result = tracker.flushPendingProgress(currentBook: nil)
        XCTAssertNil(result)
        XCTAssertEqual(wordsReadCount, 0)
    }

    func testRecordReadingProgressAndFlush() async {
        var book = Book(title: "Test", author: "A", epubPath: "/tmp/t.epub")
        try! db.saveBook(&book)
        var chapter = Chapter(
            bookId: book.id!, index: 0, title: "Ch1",
            contentHTML: "...", wordCount: 1000
        )
        try! db.saveChapter(&chapter)

        // Record progress and force-flush directly (bypass the throttled timer)
        tracker.recordReadingProgress(
            chapter: chapter,
            currentPercent: 0.1,
            furthestPercent: 0.1,
            scrollOffset: 100,
            bookId: book.id!,
            whenReadyToFlush: {}
        )

        _ = tracker.flushPendingProgress(currentBook: book)

        XCTAssertEqual(wordsReadCount, 100)
        let savedBook = try! db.fetchAllBooks().first!
        XCTAssertEqual(savedBook.currentScrollPercent, 0.1, accuracy: 0.0001)
        XCTAssertEqual(savedBook.progressPercent, 0.1, accuracy: 0.0001)

        let savedChapter = try! db.fetchChapters(for: savedBook).first!
        XCTAssertEqual(savedChapter.maxScrollReached, 0.1, accuracy: 0.0001)
    }

    func testFurthestPercentPersists() async {
        var book = Book(title: "Test2", author: "A", epubPath: "/tmp/t2.epub")
        try! db.saveBook(&book)
        var chapter = Chapter(
            bookId: book.id!, index: 0, title: "Ch1",
            contentHTML: "...", wordCount: 1000
        )
        try! db.saveChapter(&chapter)

        // Set up the book progress cache so flush computes weighted overall progress
        tracker.updateBookProgressCache(book: book, chapters: [chapter])

        // First record: 0.3
        tracker.recordReadingProgress(
            chapter: chapter,
            currentPercent: 0.05,
            furthestPercent: 0.3,
            scrollOffset: 50,
            bookId: book.id!,
            whenReadyToFlush: {}
        )
        let book1 = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, 300)

        // Second record: lower furthest (0.2) should not regress
        let savedChapter = try! db.fetchChapters(for: book).first!
        wordsReadCount = 0
        tracker.recordReadingProgress(
            chapter: savedChapter,
            currentPercent: 0.2,
            furthestPercent: 0.2,
            scrollOffset: 200,
            bookId: book.id!,
            whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book1)

        // wordsRead should not increase (furthest didn't advance)
        XCTAssertEqual(wordsReadCount, 0)
        let savedBook = try! db.fetchAllBooks().first!
        // With the cache set up, progress is wordsRead/totalWords = 300/1000
        XCTAssertEqual(savedBook.progressPercent, 0.3, accuracy: 0.0001)
    }

    // MARK: - Book Progress Cache

    func testBookProgressWithWordCounts() async {
        var book = Book(title: "Weighted", author: "A", epubPath: "/tmp/w.epub", chapterCount: 2)
        try! db.saveBook(&book)

        var c1 = Chapter(
            bookId: book.id!, index: 0, title: "Ch1",
            contentHTML: "...", wordCount: 1000
        )
        var c2 = Chapter(
            bookId: book.id!, index: 1, title: "Ch2",
            contentHTML: "...", wordCount: 500
        )
        try! db.saveChapter(&c1)
        try! db.saveChapter(&c2)

        tracker.updateBookProgressCache(book: book, chapters: [c1, c2])

        // Read 50% of chapter 1 (1000 words) = 500 words
        tracker.recordReadingProgress(
            chapter: c1,
            currentPercent: 0.5,
            furthestPercent: 0.5,
            scrollOffset: 0,
            bookId: book.id!,
            whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)

        let savedBook1 = try! db.fetchAllBooks().first!
        // 500 / 1500 total words
        XCTAssertEqual(savedBook1.progressPercent, 1.0 / 3.0, accuracy: 0.0001)

        // Read 50% of chapter 2 (500 words) = 250 more → 750 / 1500
        tracker.recordReadingProgress(
            chapter: c2,
            currentPercent: 0.5,
            furthestPercent: 0.5,
            scrollOffset: 0,
            bookId: book.id!,
            whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)

        let savedBook2 = try! db.fetchAllBooks().first!
        XCTAssertEqual(savedBook2.progressPercent, 0.5, accuracy: 0.0001)
    }

    func testUpdateBookProgressCacheSyncsMaxScroll() async {
        var book = Book(title: "Sync", author: "A", epubPath: "/tmp/s.epub")
        try! db.saveBook(&book)
        var chapter = Chapter(
            bookId: book.id!, index: 0, title: "Ch1",
            contentHTML: "...", wordCount: 500
        )
        try! db.saveChapter(&chapter)

        // Pre-set maxScrollReached to 0.4 in the chapter
        chapter.maxScrollReached = 0.4
        tracker.updateBookProgressCache(book: book, chapters: [chapter])

        // Recording 0.2 should not add words (cache says max is 0.4)
        tracker.recordReadingProgress(
            chapter: chapter,
            currentPercent: 0.2,
            furthestPercent: 0.2,
            scrollOffset: 200,
            bookId: book.id!,
            whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, 0)
    }

    // MARK: - Callback

    func testOnWordsReadNotCalledWhenNoProgress() async {
        var book = Book(title: "NoProgress", author: "A", epubPath: "/tmp/np.epub")
        try! db.saveBook(&book)
        var chapter = Chapter(
            bookId: book.id!, index: 0, title: "Ch1",
            contentHTML: "...", wordCount: 1000
        )
        try! db.saveChapter(&chapter)

        // Flush with no pending progress
        _ = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, 0)

        // Record but flush immediately, then flush again (nothing pending)
        tracker.recordReadingProgress(
            chapter: chapter,
            currentPercent: 0.0,
            furthestPercent: 0.0,
            scrollOffset: 0,
            bookId: book.id!,
            whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)
        let countAfterFirstFlush = wordsReadCount

        _ = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, countAfterFirstFlush)
    }

    func testMultipleCallsAccumulateWords() async {
        var book = Book(title: "Accum", author: "A", epubPath: "/tmp/a.epub")
        try! db.saveBook(&book)
        var chapter = Chapter(
            bookId: book.id!, index: 0, title: "Ch1",
            contentHTML: "...", wordCount: 1000
        )
        try! db.saveChapter(&chapter)

        // First: 0.1 → 100 words
        tracker.recordReadingProgress(
            chapter: chapter, currentPercent: 0.1, furthestPercent: 0.1,
            scrollOffset: 100, bookId: book.id!, whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, 100)

        // Second: 0.3 → 200 more words (delta from 0.1 to 0.3)
        let savedChapter = try! db.fetchChapters(for: book).first!
        tracker.recordReadingProgress(
            chapter: savedChapter, currentPercent: 0.3, furthestPercent: 0.3,
            scrollOffset: 300, bookId: book.id!, whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, 300)

        // Third: 0.3 again → no change
        let savedChapter2 = try! db.fetchChapters(for: book).first!
        tracker.recordReadingProgress(
            chapter: savedChapter2, currentPercent: 0.3, furthestPercent: 0.3,
            scrollOffset: 300, bookId: book.id!, whenReadyToFlush: {}
        )
        _ = tracker.flushPendingProgress(currentBook: book)
        XCTAssertEqual(wordsReadCount, 300)
    }
}
