import Foundation
import GRDB

struct Annotation: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var chapterId: Int64
    var type: AnnotationType
    var title: String
    var content: String
    var sourceQuote: String
    var sourceOffset: Int  // Character offset in chapter
    var webGrounded: Bool = false
    var sourceURL: String?

    static let databaseTableName = "annotations"

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Annotation Type

enum AnnotationType: String, Codable {
    case insight      // Deep analysis, connections
    case context      // Historical/real-world context
    case trivia       // Interesting facts
    case worldBuilding // In-universe lore
    case character    // Character background

    var icon: String {
        switch self {
        case .insight: return "lightbulb.fill"
        case .context: return "globe"
        case .trivia: return "star.fill"
        case .worldBuilding: return "building.2.fill"
        case .character: return "person.fill"
        }
    }

    var label: String {
        switch self {
        case .insight: return "Insight"
        case .context: return "Context"
        case .trivia: return "Trivia"
        case .worldBuilding: return "World"
        case .character: return "Character"
        }
    }
}

// MARK: - Column Definitions

extension Annotation {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let chapterId = Column(CodingKeys.chapterId)
        static let type = Column(CodingKeys.type)
        static let title = Column(CodingKeys.title)
        static let content = Column(CodingKeys.content)
        static let sourceQuote = Column(CodingKeys.sourceQuote)
        static let sourceOffset = Column(CodingKeys.sourceOffset)
        static let webGrounded = Column(CodingKeys.webGrounded)
        static let sourceURL = Column(CodingKeys.sourceURL)
    }
}
