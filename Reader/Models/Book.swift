import Foundation
import GRDB

struct Book: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var title: String
    var author: String
    var coverPath: String?
    var epubPath: String
    var progressPercent: Double = 0
    var currentChapter: Int = 0
    var currentScrollPercent: Double = 0
    var currentScrollOffset: Double = 0
    var chapterCount: Int = 0
    var processedFully: Bool = false
    var createdAt: Date = Date()
    var lastReadAt: Date?

    static let databaseTableName = "books"

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }

    // MARK: - Computed

    var coverURL: URL? {
        guard let path = coverPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var displayProgress: String {
        String(format: "%.0f%%", progressPercent * 100)
    }

    // MARK: - Relationships

    static let chapters = hasMany(Chapter.self)

    var chapters: QueryInterfaceRequest<Chapter> {
        request(for: Book.chapters).order(Chapter.Columns.index)
    }
}

// MARK: - Column Definitions

extension Book {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let title = Column(CodingKeys.title)
        static let author = Column(CodingKeys.author)
        static let coverPath = Column(CodingKeys.coverPath)
        static let epubPath = Column(CodingKeys.epubPath)
        static let progressPercent = Column(CodingKeys.progressPercent)
        static let currentChapter = Column(CodingKeys.currentChapter)
        static let currentScrollPercent = Column(CodingKeys.currentScrollPercent)
        static let currentScrollOffset = Column(CodingKeys.currentScrollOffset)
        static let chapterCount = Column(CodingKeys.chapterCount)
        static let processedFully = Column(CodingKeys.processedFully)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastReadAt = Column(CodingKeys.lastReadAt)
    }
}
