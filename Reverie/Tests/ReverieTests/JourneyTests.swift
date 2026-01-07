import XCTest
import GRDB
@testable import Reverie

@MainActor
final class JourneyTests: XCTestCase {
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
    func testWordCountingComplexDelta() async {
        var book = Book(title: "Test Book", author: "Author", epubPath: "/tmp/test.epub")
        try! db.saveBook(&book)
        appState.currentBook = book
        
        var chapter = Chapter(
            bookId: book.id!,
            index: 0,
            title: "Test Chapter",
            contentHTML: "...",
            wordCount: 1000
        )
        try! db.saveChapter(&chapter)
        
        appState.updateChapterProgress(chapter: chapter, scrollPercent: 0.1, scrollOffset: 100)
        try! await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(self.appState.readingStats.totalWords, 100)
        
        let freshChapter = try! self.db.fetchChapters(for: book).first!
        self.appState.updateChapterProgress(chapter: freshChapter, scrollPercent: 0.3, scrollOffset: 300)
        try! await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(self.appState.readingStats.totalWords, 300)
        
        let finalChapter = try! self.db.fetchChapters(for: book).first!
        self.appState.updateChapterProgress(chapter: finalChapter, scrollPercent: 0.2, scrollOffset: 200)
        try! await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(self.appState.readingStats.totalWords, 300)
    }

    @MainActor
    func testAnnotationSorting() {
        var annotations = [
            Annotation(chapterId: 1, type: .science, title: "Last", content: "...", sourceBlockId: 10),
            Annotation(chapterId: 1, type: .science, title: "First", content: "...", sourceBlockId: 1),
            Annotation(chapterId: 1, type: .science, title: "Middle", content: "...", sourceBlockId: 5)
        ]
        
        annotations.sort { $0.sourceBlockId < $1.sourceBlockId }
        
        XCTAssertEqual(annotations[0].title, "First")
        XCTAssertEqual(annotations[1].title, "Middle")
        XCTAssertEqual(annotations[2].title, "Last")
    }

    @MainActor
    func testAsyncChapterSwitchRaceCondition() async throws {
        // Setup two chapters
        var book = Book(title: "Race Test", author: "Author", epubPath: "/tmp/race.epub")
        try! db.saveBook(&book)
        
        var c1 = Chapter(bookId: book.id!, index: 0, title: "Chapter 1", contentHTML: "<p>C1</p>")
        try! db.saveChapter(&c1)
        var c2 = Chapter(bookId: book.id!, index: 1, title: "Chapter 2", contentHTML: "<p>C2</p>")
        try! db.saveChapter(&c2)
        
        // Use a simple actor to manage the "UI" state safely across tasks
        actor TestState {
            var currentChapterId: Int64
            var uiAnnotations: [Annotation] = []
            
            init(initialChapterId: Int64) {
                self.currentChapterId = initialChapterId
            }
            
            func setChapterId(_ id: Int64) {
                self.currentChapterId = id
            }
            
            func addAnnotationIfStillOnChapter(_ annotation: Annotation, chapterId: Int64) {
                if self.currentChapterId == chapterId {
                    uiAnnotations.append(annotation)
                }
            }
            
            var annotations: [Annotation] { uiAnnotations }
        }
        
        let state = TestState(initialChapterId: c1.id!)
        
        // Start "processing" C1
        let processC1 = Task {
            // Simulate LLM delay
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            
            let result = Annotation(chapterId: c1.id!, type: .science, title: "C1 Note", content: "...", sourceBlockId: 1)
            
            // The "Safe" check pattern
            await state.addAnnotationIfStillOnChapter(result, chapterId: c1.id!)
        }
        
        // Immediately switch to C2
        await state.setChapterId(c2.id!)
        
        await processC1.value
        
        let finalAnnotations = await state.annotations
        XCTAssertTrue(finalAnnotations.isEmpty, "UI Annotations should be empty because we switched to Chapter 2")
    }
}
