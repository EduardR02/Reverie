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

    static let databaseTableName = "quizzes"

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Column Definitions

extension Quiz {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let chapterId = Column(CodingKeys.chapterId)
        static let question = Column(CodingKeys.question)
        static let answer = Column(CodingKeys.answer)
        static let sourceBlockId = Column(CodingKeys.sourceBlockId)
        static let userAnswered = Column(CodingKeys.userAnswered)
        static let userCorrect = Column(CodingKeys.userCorrect)
    }
}
