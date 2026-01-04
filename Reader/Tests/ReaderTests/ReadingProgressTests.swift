import XCTest
import GRDB
@testable import Reader

@MainActor
final class ReadingProgressTests: XCTestCase {
    var db: DatabaseService!
    var appState: AppState!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let queue = try! DatabaseQueue()
        db = DatabaseService(dbQueue: queue)
        appState = AppState(database: db)
    }

    @MainActor
    func testRecordReadingProgressUsesFurthest() {
        var book = Book(title: "Progress Book", author: "Author", epubPath: "/tmp/test.epub")
        try! db.saveBook(&book)
        appState.currentBook = book

        var chapter = Chapter(
            bookId: book.id!,
            index: 0,
            title: "Chapter",
            contentHTML: "...",
            wordCount: 1000
        )
        try! db.saveChapter(&chapter)

        appState.recordReadingProgress(chapter: chapter, currentPercent: 0.1, furthestPercent: 0.1, scrollOffset: 100)

        let done = XCTestExpectation(description: "All saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            XCTAssertEqual(self.appState.readingStats.totalWords, 100)
            let savedBook = try! self.db.fetchAllBooks().first!
            XCTAssertEqual(savedBook.currentScrollPercent, 0.1, accuracy: 0.0001)
            XCTAssertEqual(savedBook.progressPercent, 0.1, accuracy: 0.0001)

            let savedChapter = try! self.db.fetchChapters(for: savedBook).first!
            XCTAssertEqual(savedChapter.maxScrollReached, 0.1, accuracy: 0.0001)

            // Move back, but furthest advances
            self.appState.recordReadingProgress(chapter: savedChapter, currentPercent: 0.05, furthestPercent: 0.3, scrollOffset: 50)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                XCTAssertEqual(self.appState.readingStats.totalWords, 300)
                let savedBook2 = try! self.db.fetchAllBooks().first!
                XCTAssertEqual(savedBook2.currentScrollPercent, 0.05, accuracy: 0.0001)
                XCTAssertEqual(savedBook2.progressPercent, 0.3, accuracy: 0.0001)

                let savedChapter2 = try! self.db.fetchChapters(for: savedBook2).first!
                XCTAssertEqual(savedChapter2.maxScrollReached, 0.3, accuracy: 0.0001)

                // No double counting on same furthest
                self.appState.recordReadingProgress(chapter: savedChapter2, currentPercent: 0.2, furthestPercent: 0.3, scrollOffset: 200)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    XCTAssertEqual(self.appState.readingStats.totalWords, 300)
                    done.fulfill()
                }
            }
        }

        wait(for: [done], timeout: 6.0)
    }

    @MainActor
    func testBookProgressUsesWordCounts() {
        var book = Book(title: "Weighted Book", author: "Author", epubPath: "/tmp/test.epub", chapterCount: 2)
        try! db.saveBook(&book)
        appState.currentBook = book

        var c1 = Chapter(
            bookId: book.id!,
            index: 0,
            title: "Chapter 1",
            contentHTML: "...",
            wordCount: 1000
        )
        var c2 = Chapter(
            bookId: book.id!,
            index: 1,
            title: "Chapter 2",
            contentHTML: "...",
            wordCount: 500
        )
        try! db.saveChapter(&c1)
        try! db.saveChapter(&c2)

        appState.updateBookProgressCache(book: book, chapters: [c1, c2])
        appState.currentChapterIndex = 0
        appState.recordReadingProgress(chapter: c1, currentPercent: 0.5, furthestPercent: 0.5, scrollOffset: 0)

        let done = XCTestExpectation(description: "Weighted progress saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let savedBook = try! self.db.fetchAllBooks().first!
            XCTAssertEqual(savedBook.progressPercent, 1.0 / 3.0, accuracy: 0.0001)

            self.appState.currentChapterIndex = 1
            self.appState.recordReadingProgress(chapter: c2, currentPercent: 0.5, furthestPercent: 0.5, scrollOffset: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let savedBook2 = try! self.db.fetchAllBooks().first!
                XCTAssertEqual(savedBook2.progressPercent, 0.5, accuracy: 0.0001)
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 5.0)
    }
}
