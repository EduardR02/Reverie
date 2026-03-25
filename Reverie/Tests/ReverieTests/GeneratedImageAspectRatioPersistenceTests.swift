import XCTest
import GRDB
@testable import Reverie

final class GeneratedImageAspectRatioPersistenceTests: XCTestCase {
    private var database: DatabaseService!

    override func setUp() {
        super.setUp()
        database = try! DatabaseService(dbQueue: DatabaseQueue())
    }

    func testGeneratedImageAspectRatioPersistsInDatabase() throws {
        var book = Book(title: "T", author: "A", epubPath: "P")
        try database.saveBook(&book)

        var chapter = Chapter(bookId: book.id!, index: 0, title: "C", contentHTML: "H")
        try database.saveChapter(&chapter)

        var image = GeneratedImage(
            chapterId: chapter.id!,
            excerpt: "Excerpt",
            prompt: "Prompt",
            imagePath: "",
            sourceBlockId: 1,
            aspectRatio: "9:16",
            status: .failed,
            failureReason: "Blocked"
        )
        try database.saveImage(&image)

        let fetched = try database.fetchImages(for: chapter)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].aspectRatio, "9:16")
    }

    func testGeneratedImageDecodesWithoutAspectRatio() throws {
        let json = """
        {
          "id": 1,
          "chapterId": 2,
          "prompt": "Prompt",
          "imagePath": "/tmp/test.png",
          "sourceBlockId": 3,
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let image = try decoder.decode(GeneratedImage.self, from: Data(json.utf8))

        XCTAssertNil(image.aspectRatio)
    }

    func testAspectRatioMigrationPreservesExistingGeneratedImages() throws {
        let dbQueue = try DatabaseQueue()
        try applyLegacyMigrations(to: dbQueue)

        let createdAt = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO books (id, title, author, epubPath, progressPercent, currentChapter, currentScrollPercent, currentScrollOffset, chapterCount, importStatus, processedFully, createdAt, classificationStatus, isFinished) VALUES (1, 'Book', 'Author', 'book.epub', 0, 0, 0, 0, 1, 'complete', 0, ?, 'completed', 0)",
                arguments: [createdAt]
            )
            try db.execute(
                sql: "INSERT INTO chapters (id, bookId, \"index\", title, contentHTML, blockCount, processed, wordCount, isGarbage, userOverride, maxScrollReached) VALUES (1, 1, 0, 'Chapter', '<p>Hi</p>', 1, 0, 0, 0, 0, 0)")
            try db.execute(
                sql: "INSERT INTO generated_images (id, chapterId, prompt, imagePath, sourceBlockId, createdAt, status, failureReason, excerpt) VALUES (1, 1, 'Prompt', '/tmp/image.png', 4, ?, 'failed', 'Blocked', 'Excerpt')",
                arguments: [createdAt]
            )
        }

        _ = try DatabaseService(dbQueue: dbQueue)

        let columnNames = try dbQueue.read { db in
            try db.columns(in: "generated_images").map(\.name)
        }
        XCTAssertTrue(columnNames.contains("aspectRatio"))

        let row = try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT prompt, excerpt, status, failureReason, aspectRatio FROM generated_images WHERE id = 1"
            )
        }

        XCTAssertEqual(row?["prompt"] as String?, "Prompt")
        XCTAssertEqual(row?["excerpt"] as String?, "Excerpt")
        XCTAssertEqual(row?["status"] as String?, "failed")
        XCTAssertEqual(row?["failureReason"] as String?, "Blocked")
        XCTAssertNil(row?["aspectRatio"] as String?)
    }

    private func applyLegacyMigrations(to dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
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

            try db.create(table: "lifetime_stats") { t in
                t.column("id", .integer).primaryKey()
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
                t.column("dateKey", .text).primaryKey()
                t.column("seconds", .double).notNull().defaults(to: 0)
            }

            try db.execute(sql: "INSERT INTO lifetime_stats (id) VALUES (1)")
            try db.create(index: "idx_chapters_bookId", on: "chapters", columns: ["bookId"])
            try db.create(index: "idx_annotations_chapterId", on: "annotations", columns: ["chapterId"])
            try db.create(index: "idx_quizzes_chapterId", on: "quizzes", columns: ["chapterId"])
            try db.create(index: "idx_generated_images_chapterId", on: "generated_images", columns: ["chapterId"])
            try db.create(index: "idx_footnotes_chapterId", on: "footnotes", columns: ["chapterId"])
        }

        migrator.registerMigration("v2_image_status") { db in
            try db.alter(table: "generated_images") { t in
                t.add(column: "status", .text).notNull().defaults(to: GeneratedImage.Status.success.rawValue)
                t.add(column: "failureReason", .text)
            }
        }

        migrator.registerMigration("v3_image_excerpt") { db in
            try db.alter(table: "generated_images") { t in
                t.add(column: "excerpt", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE generated_images SET excerpt = prompt WHERE excerpt = ''")
        }

        try migrator.migrate(dbQueue)
    }
}
