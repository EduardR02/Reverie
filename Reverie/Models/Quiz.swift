import Foundation
import GRDB

struct Quiz: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var chapterId: Int64
    var question: String
    var answer: String
    var sourceBlockId: Int  // Block number [N] containing the answer
    var userAnswered: Bool = false
    var userCorrect: Bool?
    var qualityFeedback: QualityFeedback?

    enum QualityFeedback: String, Codable {
        case good
        case garbage
    }

    static let databaseTableName = "quizzes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Column Definitions

extension Quiz {
    enum Columns: String, ColumnExpression {
        case id, chapterId, question, answer, sourceBlockId, userAnswered, userCorrect, qualityFeedback
    }
}
