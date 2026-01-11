import Foundation
import GRDB

struct Chapter: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var bookId: Int64
    var index: Int
    var title: String
    var contentHTML: String
    var contentText: String?         // Clean text with [N] block markers for LLM
    var blockCount: Int = 0          // Number of content blocks
    var resourcePath: String? = nil
    var summary: String?
    var rollingSummary: String?      // Summary of all chapters up to this one
    var processed: Bool = false
    var wordCount: Int = 0
    var isGarbage: Bool = false      // LLM classified as non-content
    var userOverride: Bool = false   // User clicked "Process Anyway"
    var maxScrollReached: Double = 0

    static let databaseTableName = "chapters"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let book = belongsTo(Book.self)
    static let annotations = hasMany(Annotation.self)
    static let quizzes = hasMany(Quiz.self)
    static let generatedImages = hasMany(GeneratedImage.self)
    static let footnotes = hasMany(Footnote.self)

    var annotations: QueryInterfaceRequest<Annotation> {
        request(for: Chapter.annotations).order(Column("sourceBlockId"))
    }

    var quizzes: QueryInterfaceRequest<Quiz> {
        request(for: Chapter.quizzes).order(Column("sourceBlockId"))
    }

    var images: QueryInterfaceRequest<GeneratedImage> {
        request(for: Chapter.generatedImages).order(Column("sourceBlockId"))
    }

    var footnotes: QueryInterfaceRequest<Footnote> {
        request(for: Chapter.footnotes).order(Column("sourceBlockId"))
    }

    // MARK: - Computed

    /// Get cached content text and block count, or parse HTML if not cached
    func getContentText() -> (text: String, blockCount: Int) {
        if let text = contentText {
            return (text, blockCount)
        }
        let (blocks, cleanText) = ContentBlockParser().parse(html: contentHTML)
        return (cleanText, blocks.count)
    }
}

// MARK: - Column Definitions

extension Chapter {
    enum Columns: String, ColumnExpression {
        case id, bookId, index, title, contentHTML, contentText, blockCount,
             resourcePath, summary, rollingSummary, processed, wordCount,
             isGarbage, userOverride, maxScrollReached
    }

    /// Whether this chapter should skip automatic AI processing
    var shouldSkipAutoProcessing: Bool {
        isGarbage && !userOverride
    }
}

struct ChapterMetadata: Identifiable, Codable, FetchableRecord {
    var id: Int64?
    var bookId: Int64
    var index: Int
    var title: String
    var processed: Bool
    var wordCount: Int
    var isGarbage: Bool
    var userOverride: Bool

    var shouldSkipAutoProcessing: Bool {
        isGarbage && !userOverride
    }
}
