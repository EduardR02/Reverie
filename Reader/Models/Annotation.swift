import Foundation
import GRDB

struct Annotation: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var chapterId: Int64
    var type: AnnotationType
    var title: String
    var content: String
    var sourceBlockId: Int  // Block number [N] this insight relates to
    var isSeen: Bool = false

    static let databaseTableName = "annotations"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Annotation Type

enum AnnotationType: String, Codable {
    case science       // Real science/tech behind concepts
    case history       // Historical events, figures, parallels
    case philosophy    // Questions being explored, thought experiments
    case connection    // Links to other works, mythology, traditions
    case world         // In-universe logic, unstated implications

    var icon: String {
        switch self {
        case .science: return "atom"
        case .history: return "clock.arrow.circlepath"
        case .philosophy: return "brain"
        case .connection: return "link"
        case .world: return "globe"
        }
    }

    var label: String {
        switch self {
        case .science: return "Science"
        case .history: return "History"
        case .philosophy: return "Philosophy"
        case .connection: return "Links"
        case .world: return "World"
        }
    }
}

// MARK: - Column Definitions

extension Annotation {
    enum Columns: String, ColumnExpression {
        case id, chapterId, type, title, content, sourceBlockId, isSeen
    }
}
