import Foundation
import GRDB

final class DatabaseService {
    static let shared = DatabaseService()

    private let dbQueue: DatabaseQueue
    private let databaseFilename = "reader_v2.sqlite"

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let readerDir = appSupport.appendingPathComponent("Reader", isDirectory: true)

        try? fileManager.createDirectory(at: readerDir, withIntermediateDirectories: true)

        let dbPath = readerDir.appendingPathComponent(databaseFilename).path
        dbQueue = try! DatabaseQueue(path: dbPath)

        try! setupDatabase()
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
            }

            try db.create(table: "quizzes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("answer", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()
                t.column("userAnswered", .boolean).notNull().defaults(to: false)
                t.column("userCorrect", .boolean)
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
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Lifetime Stats Operations

    func fetchLifetimeStats() throws -> ReadingStats {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM lifetime_stats WHERE id = 1")!
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
            
            // Save daily logs
            for (dateKey, seconds) in stats.dailyLog {
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

    func saveBook(_ book: inout Book) throws {
        try dbQueue.write { db in
            try book.save(db)
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

    func saveChapter(_ chapter: inout Chapter) throws {
        try dbQueue.write { db in
            try chapter.save(db)
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
