import Foundation
import GRDB

enum DatabaseError: Error {
    case connectionFailed(String)
    case migrationFailed(String)
    case statsNotFound
}

final class DatabaseService: @unchecked Sendable {
    // The default instance for the app
    @MainActor static let shared = try! DatabaseService()

    private let dbQueue: DatabaseQueue

    /// Standard initializer for persistent storage
    init() throws {
        let fileManager = FileManager.default
        let readerDir = LibraryPaths.readerRoot

        do {
            try fileManager.createDirectory(at: readerDir, withIntermediateDirectories: true)
        } catch {
            throw DatabaseError.connectionFailed("Could not create database directory: \(error.localizedDescription)")
        }

        let databaseURL = LibraryPaths.databaseURL
        do {
            self.dbQueue = try DatabaseQueue(path: databaseURL.path)
        } catch {
            throw DatabaseError.connectionFailed("Could not open database: \(error.localizedDescription)")
        }

        try setupDatabase()
    }
    
    /// Initializer for testing (e.g., in-memory)
    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try setupDatabase()
    }

    private func setupDatabase() throws {
        var migrator = DatabaseMigrator()
        
        #if DEBUG
        // During development, nuke and recreate if the schema in "v1" changes.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // --- Library ---
            try db.create(table: "books") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("author", .text).notNull()
                t.column("coverPath", .text)
                t.column("epubPath", .text).notNull()
                t.column("progressPercent", .double).notNull().defaults(to: 0)
                t.column("currentChapter", .integer).notNull().defaults(to: 0)
                t.column("currentScrollPercent", .double).notNull().defaults(to: 0)
                t.column("currentScrollOffset", .double).notNull().defaults(to: 0)
                t.column("chapterCount", .integer).notNull().defaults(to: 0)
                t.column("importStatus", .text).notNull().defaults(to: "complete")
                t.column("processedFully", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastReadAt", .datetime)
                t.column("classificationStatus", .text).notNull()
                t.column("classificationError", .text)
                t.column("isFinished", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "chapters") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .integer).notNull().references("books", onDelete: .cascade)
                t.column("index", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("contentHTML", .text).notNull()
                t.column("contentText", .text)
                t.column("blockCount", .integer).notNull().defaults(to: 0)
                t.column("resourcePath", .text)
                t.column("summary", .text)
                t.column("rollingSummary", .text)
                t.column("processed", .boolean).notNull().defaults(to: false)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("isGarbage", .boolean).notNull().defaults(to: false)
                t.column("userOverride", .boolean).notNull().defaults(to: false)
                t.column("maxScrollReached", .double).notNull().defaults(to: 0)
            }

            // --- Annotations & Content ---
            try db.create(table: "annotations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()
                t.column("isSeen", .boolean).notNull().defaults(to: false)
                t.column("refinedSearchQuery", .text)
            }

            try db.create(table: "quizzes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("answer", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()
                t.column("userAnswered", .boolean).notNull().defaults(to: false)
                t.column("userCorrect", .boolean)
                t.column("qualityFeedback", .text)
            }

            try db.create(table: "generated_images") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("prompt", .text).notNull()
                t.column("imagePath", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "footnotes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("marker", .text).notNull()
                t.column("content", .text).notNull()
                t.column("refId", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()
            }

            // --- Journey Stats ---
            try db.create(table: "lifetime_stats") { t in
                t.column("id", .integer).primaryKey() // Always row 1
                t.column("totalSeconds", .double).notNull().defaults(to: 0)
                t.column("totalWords", .integer).notNull().defaults(to: 0)
                t.column("insightsSeen", .integer).notNull().defaults(to: 0)
                t.column("followupsAsked", .integer).notNull().defaults(to: 0)
                t.column("imagesGenerated", .integer).notNull().defaults(to: 0)
                t.column("totalBooksFinished", .integer).notNull().defaults(to: 0)
                t.column("tokensInput", .integer).notNull().defaults(to: 0)
                t.column("tokensReasoning", .integer).notNull().defaults(to: 0)
                t.column("tokensOutput", .integer).notNull().defaults(to: 0)
                t.column("currentStreak", .integer).notNull().defaults(to: 0)
                t.column("lastReadDate", .datetime)
            }

            try db.create(table: "daily_reading") { t in
                t.column("dateKey", .text).primaryKey() // YYYY-MM-DD
                t.column("seconds", .double).notNull().defaults(to: 0)
            }
            
            // Seed the single stats row
            try db.execute(sql: "INSERT INTO lifetime_stats (id) VALUES (1)")

            // --- Indexes ---
            try db.create(index: "idx_chapters_bookId", on: "chapters", columns: ["bookId"])
            try db.create(index: "idx_annotations_chapterId", on: "annotations", columns: ["chapterId"])
            try db.create(index: "idx_quizzes_chapterId", on: "quizzes", columns: ["chapterId"])
            try db.create(index: "idx_generated_images_chapterId", on: "generated_images", columns: ["chapterId"])
            try db.create(index: "idx_footnotes_chapterId", on: "footnotes", columns: ["chapterId"])
        }

        do {
            try migrator.migrate(dbQueue)
        } catch {
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }

    // MARK: - Lifetime Stats Operations

    func fetchLifetimeStats() throws -> ReadingStats {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM lifetime_stats WHERE id = 1") else {
                return ReadingStats()
            }
            var stats = ReadingStats()
            stats.totalSeconds = row["totalSeconds"]
            stats.totalWords = row["totalWords"]
            stats.insightsSeen = row["insightsSeen"]
            stats.followupsAsked = row["followupsAsked"]
            stats.imagesGenerated = row["imagesGenerated"]
            stats.totalBooks = row["totalBooksFinished"]
            stats.tokensInput = row["tokensInput"]
            stats.tokensReasoning = row["tokensReasoning"]
            stats.tokensOutput = row["tokensOutput"]
            stats.currentStreak = row["currentStreak"]
            stats.lastReadDate = row["lastReadDate"]
            
            // Load daily log
            let dailyRows = try Row.fetchAll(db, sql: "SELECT * FROM daily_reading")
            for dRow in dailyRows {
                stats.dailyLog[dRow["dateKey"]] = dRow["seconds"]
            }
            
            return stats
        }
    }

    func saveLifetimeStats(_ stats: ReadingStats) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE lifetime_stats SET 
                    totalSeconds = ?, totalWords = ?, insightsSeen = ?, 
                    followupsAsked = ?, imagesGenerated = ?, totalBooksFinished = ?, 
                    tokensInput = ?, tokensReasoning = ?, tokensOutput = ?, 
                    currentStreak = ?, lastReadDate = ?
                WHERE id = 1
                """,
                arguments: [
                    stats.totalSeconds, stats.totalWords, stats.insightsSeen,
                    stats.followupsAsked, stats.imagesGenerated, stats.totalBooks,
                    stats.tokensInput, stats.tokensReasoning, stats.tokensOutput,
                    stats.currentStreak, stats.lastReadDate
                ]
            )
            
            // Save daily logs - only update the current day to avoid O(N) upserts
            let dateKey = ReadingStats.dateKey(for: Date())
            if let seconds = stats.dailyLog[dateKey] {
                try db.execute(
                    sql: "INSERT INTO daily_reading (dateKey, seconds) VALUES (?, ?) ON CONFLICT(dateKey) DO UPDATE SET seconds = excluded.seconds",
                    arguments: [dateKey, seconds]
                )
            }
        }
    }

    // MARK: - Book Operations

    func fetchAllBooks() throws -> [Book] {
        try dbQueue.read { db in
            try Book.order(Book.Columns.lastReadAt.desc).fetchAll(db)
        }
    }

    func fetchBook(id: Int64) throws -> Book? {
        try dbQueue.read { db in
            try Book.fetchOne(db, key: id)
        }
    }

    func saveBook(_ book: inout Book) throws {
        try dbQueue.write { db in
            try book.save(db)
        }
    }

    func updateBookClassificationStatus(id: Int64, status: ClassificationStatus, error: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE books SET classificationStatus = ?, classificationError = ? WHERE id = ?",
                arguments: [status.rawValue, error, id]
            )
        }
    }

    func updateBookImportStatus(id: Int64, status: ImportStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE books SET importStatus = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    func deleteBook(_ book: Book) throws {
        try dbQueue.write { db in
            _ = try book.delete(db)
        }
    }

    // MARK: - Chapter Operations

    func fetchChapters(for book: Book) throws -> [Chapter] {
        try dbQueue.read { db in
            try book.chapters.fetchAll(db)
        }
    }

    func fetchChapterMetadata(for book: Book) throws -> [ChapterMetadata] {
        try dbQueue.read { db in
            try Chapter.filter(Column("bookId") == book.id)
                .order(Column("index"))
                .select(
                    Column("id"),
                    Column("bookId"),
                    Column("index"),
                    Column("title"),
                    Column("processed"),
                    Column("wordCount"),
                    Column("isGarbage"),
                    Column("userOverride")
                )
                .asRequest(of: ChapterMetadata.self)
                .fetchAll(db)
        }
    }

    func saveChapter(_ chapter: inout Chapter) throws {
        try dbQueue.write { db in
            try chapter.save(db)
        }
    }

    func updateChapterGarbageStatus(bookId: Int64, classifications: [Int: Bool]) throws {
        try dbQueue.write { db in
            for (index, isGarbage) in classifications {
                try db.execute(
                    sql: "UPDATE chapters SET isGarbage = ? WHERE bookId = ? AND \"index\" = ?",
                    arguments: [isGarbage, bookId, index]
                )
            }
        }
    }

    func importChapters(_ items: [(chapter: Chapter, footnotes: [Footnote])]) throws {
        try dbQueue.write { db in
            for var item in items {
                try item.chapter.save(db)
                if let chapterId = item.chapter.id {
                    for var footnote in item.footnotes {
                        footnote.chapterId = chapterId
                        try footnote.save(db)
                    }
                }
            }
        }
    }

    // MARK: - Annotation Operations

    func fetchAnnotations(for chapter: Chapter) throws -> [Annotation] {
        try dbQueue.read { db in
            try chapter.annotations.fetchAll(db)
        }
    }

    func saveAnnotation(_ annotation: inout Annotation) throws {
        try dbQueue.write { db in
            try annotation.save(db)
        }
    }

    // MARK: - Image Operations

    func saveImage(_ image: inout GeneratedImage) throws {
        try dbQueue.write { db in
            try image.save(db)
        }
    }

    func fetchImages(for chapter: Chapter) throws -> [GeneratedImage] {
        try dbQueue.read { db in
            try chapter.request(for: Chapter.generatedImages).fetchAll(db)
        }
    }

    // MARK: - Footnote Operations

    func saveFootnotes(_ footnotes: [Footnote]) throws {
        try dbQueue.write { db in
            for var footnote in footnotes {
                try footnote.save(db)
            }
        }
    }

    func fetchFootnotes(for chapter: Chapter) throws -> [Footnote] {
        try dbQueue.read { db in
            try chapter.request(for: Chapter.footnotes).fetchAll(db)
        }
    }

    // MARK: - Quiz Operations
    
    func saveQuiz(_ quiz: inout Quiz) throws {
        try dbQueue.write { db in
            try quiz.save(db)
        }
    }
    
    func saveAnalysis(_ analysis: LLMService.ChapterAnalysis, chapterId: Int64, blockCount: Int) throws {
        try dbQueue.write { db in
            for data in analysis.annotations {
                let type = AnnotationType(rawValue: data.type) ?? .science
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount
                    ? data.sourceBlockId : 1
                var annotation = Annotation(
                    chapterId: chapterId,
                    type: type,
                    title: data.title,
                    content: data.content,
                    sourceBlockId: validBlockId
                )
                try annotation.save(db)
            }

            for data in analysis.quizQuestions {
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount
                    ? data.sourceBlockId : 1
                var quiz = Quiz(
                    chapterId: chapterId,
                    question: data.question,
                    answer: data.answer,
                    sourceBlockId: validBlockId
                )
                try quiz.save(db)
            }
        }
    }

    func fetchQuizzes(for chapter: Chapter) throws -> [Quiz] {
        try dbQueue.read { db in
            try chapter.request(for: Chapter.quizzes).fetchAll(db)
        }
    }

    // MARK: - Stats Summary

    struct DBStats {
        let totalInsights: Int
        let finishedBooks: Int
        let quizzesGenerated: Int
        let quizzesAnswered: Int
        let quizzesCorrect: Int
        let quizAccuracy: Double
        let imagesGenerated: Int
    }

    func fetchStats() throws -> DBStats {
        try dbQueue.read { db in
            let insightsCount = try Annotation.fetchCount(db)
            let finishedCount = try Book.filter(Book.Columns.isFinished == true).fetchCount(db)
            let imagesCount = try GeneratedImage.fetchCount(db)
            let quizzesTotal = try Quiz.fetchCount(db)
            
            let quizzes = try Quiz.filter(Quiz.Columns.userAnswered == true).fetchAll(db)
            let correct = quizzes.filter { $0.userCorrect == true }.count
            let accuracy = quizzes.isEmpty ? 0 : Double(correct) / Double(quizzes.count)
            
            return DBStats(
                totalInsights: insightsCount,
                finishedBooks: finishedCount,
                quizzesGenerated: quizzesTotal,
                quizzesAnswered: quizzes.count,
                quizzesCorrect: correct,
                quizAccuracy: accuracy,
                imagesGenerated: imagesCount
            )
        }
    }
}
