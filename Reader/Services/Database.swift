import Foundation
import GRDB

final class DatabaseService {
    static let shared = DatabaseService()

    private let dbQueue: DatabaseQueue
    private let databaseFilename = "reader_v2.sqlite"  // Fresh schema with block-based referencing

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let readerDir = appSupport.appendingPathComponent("Reader", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: readerDir, withIntermediateDirectories: true)

        let dbPath = readerDir.appendingPathComponent(databaseFilename).path
        dbQueue = try! DatabaseQueue(path: dbPath)

        try! createSchema()
    }

    // MARK: - Schema

    private func createSchema() throws {
        try dbQueue.write { db in
            try db.create(table: "books", ifNotExists: true) { t in
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
                t.column("classificationStatus", .text).notNull().defaults(to: "pending")
                t.column("classificationError", .text)
            }

            try db.create(table: "chapters", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .integer).notNull().references("books", onDelete: .cascade)
                t.column("index", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("contentHTML", .text).notNull()
                t.column("contentText", .text)  // Clean text with [N] block markers
                t.column("blockCount", .integer).notNull().defaults(to: 0)
                t.column("resourcePath", .text)
                t.column("summary", .text)
                t.column("rollingSummary", .text)
                t.column("processed", .boolean).notNull().defaults(to: false)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("isGarbage", .boolean).notNull().defaults(to: false)
                t.column("userOverride", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "annotations", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()  // Block number [N]
            }

            try db.create(table: "quizzes", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("answer", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()  // Block number [N]
                t.column("userAnswered", .boolean).notNull().defaults(to: false)
                t.column("userCorrect", .boolean)
            }

            try db.create(table: "generated_images", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("prompt", .text).notNull()
                t.column("imagePath", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()  // Block number [N]
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "footnotes", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chapterId", .integer).notNull().references("chapters", onDelete: .cascade)
                t.column("marker", .text).notNull()
                t.column("content", .text).notNull()
                t.column("refId", .text).notNull()
                t.column("sourceBlockId", .integer).notNull()  // Block number [N]
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
            if book.id == nil {
                book.id = db.lastInsertedRowID
            }
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
            if chapter.id == nil {
                chapter.id = db.lastInsertedRowID
            }
        }
    }

    // MARK: - Annotation Operations

    func fetchAnnotations(for chapter: Chapter) throws -> [Annotation] {
        try dbQueue.read { db in
            try Annotation
                .filter(Annotation.Columns.chapterId == chapter.id)
                .order(Annotation.Columns.sourceBlockId)
                .fetchAll(db)
        }
    }

    func saveAnnotation(_ annotation: inout Annotation) throws {
        try dbQueue.write { db in
            try annotation.save(db)
            if annotation.id == nil {
                annotation.id = db.lastInsertedRowID
            }
        }
    }

    // MARK: - Quiz Operations

    func fetchQuizzes(for chapter: Chapter) throws -> [Quiz] {
        try dbQueue.read { db in
            try Quiz
                .filter(Quiz.Columns.chapterId == chapter.id)
                .order(Quiz.Columns.sourceBlockId)
                .fetchAll(db)
        }
    }

    func saveQuiz(_ quiz: inout Quiz) throws {
        try dbQueue.write { db in
            try quiz.save(db)
            if quiz.id == nil {
                quiz.id = db.lastInsertedRowID
            }
        }
    }

    // MARK: - Image Operations

    func fetchImages(for chapter: Chapter) throws -> [GeneratedImage] {
        try dbQueue.read { db in
            try GeneratedImage
                .filter(GeneratedImage.Columns.chapterId == chapter.id)
                .order(GeneratedImage.Columns.sourceBlockId)
                .fetchAll(db)
        }
    }

    // MARK: - Stats

    func fetchTotalWordCount(for book: Book) throws -> Int {
        try dbQueue.read { db in
            let request = book.chapters.select(sum(Chapter.Columns.wordCount))
            return try Int.fetchOne(db, request) ?? 0
        }
    }

    func saveImage(_ image: inout GeneratedImage) throws {
        try dbQueue.write { db in
            try image.save(db)
            if image.id == nil {
                image.id = db.lastInsertedRowID
            }
        }
    }

    // MARK: - Footnote Operations

    func fetchFootnotes(for chapter: Chapter) throws -> [Footnote] {
        try dbQueue.read { db in
            try Footnote
                .filter(Footnote.Columns.chapterId == chapter.id)
                .order(Footnote.Columns.sourceBlockId)
                .fetchAll(db)
        }
    }

    func saveFootnote(_ footnote: inout Footnote) throws {
        try dbQueue.write { db in
            try footnote.save(db)
            if footnote.id == nil {
                footnote.id = db.lastInsertedRowID
            }
        }
    }

    func saveFootnotes(_ footnotes: [Footnote]) throws {
        try dbQueue.write { db in
            for var footnote in footnotes {
                try footnote.save(db)
            }
        }
    }
}
