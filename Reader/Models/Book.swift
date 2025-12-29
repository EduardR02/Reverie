import Foundation
import GRDB

enum ClassificationStatus: String, Codable {
    case pending      // Not yet attempted
    case inProgress   // Currently classifying
    case completed    // Successfully classified
    case failed       // Failed, will retry on next open
}

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
    var classificationStatus: ClassificationStatus = .pending
    var classificationError: String?
    var isFinished: Bool = false

    static let databaseTableName = "books"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
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
        request(for: Book.chapters).order(Column("index"))
    }
}

// MARK: - Column Definitions

extension Book {
    enum Columns: String, ColumnExpression {
        case id, title, author, coverPath, epubPath, progressPercent, currentChapter, 
             currentScrollPercent, currentScrollOffset, chapterCount, processedFully, 
             createdAt, lastReadAt, classificationStatus, classificationError, isFinished
    }

    /// Whether classification needs to run (pending, failed, or stuck in-progress)
    var needsClassification: Bool {
        classificationStatus == .pending
            || classificationStatus == .failed
            || classificationStatus == .inProgress
    }
}
