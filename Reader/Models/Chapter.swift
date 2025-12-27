import Foundation
import GRDB

struct Chapter: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var bookId: Int64
    var index: Int
    var title: String
    var contentHTML: String
    var summary: String?
    var rollingSummary: String?  // Summary of all chapters up to this one
    var processed: Bool = false
    var wordCount: Int = 0

    static let databaseTableName = "chapters"

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }

    // MARK: - Relationships

    static let book = belongsTo(Book.self)
    static let annotations = hasMany(Annotation.self)
    static let quizzes = hasMany(Quiz.self)
    static let images = hasMany(GeneratedImage.self)

    var annotations: QueryInterfaceRequest<Annotation> {
        request(for: Chapter.annotations).order(Annotation.Columns.sourceOffset)
    }

    var quizzes: QueryInterfaceRequest<Quiz> {
        request(for: Chapter.quizzes)
    }

    var images: QueryInterfaceRequest<GeneratedImage> {
        request(for: Chapter.images).order(GeneratedImage.Columns.sourceOffset)
    }

    // MARK: - Computed

    var readingTime: String {
        let minutes = max(1, wordCount / 200)
        return "\(minutes) min"
    }
}

// MARK: - Column Definitions

extension Chapter {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let bookId = Column(CodingKeys.bookId)
        static let index = Column(CodingKeys.index)
        static let title = Column(CodingKeys.title)
        static let contentHTML = Column(CodingKeys.contentHTML)
        static let summary = Column(CodingKeys.summary)
        static let rollingSummary = Column(CodingKeys.rollingSummary)
        static let processed = Column(CodingKeys.processed)
        static let wordCount = Column(CodingKeys.wordCount)
    }
}
