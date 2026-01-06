import Foundation
import GRDB

struct Footnote: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var chapterId: Int64
    var marker: String         // The footnote reference marker (e.g., "1", "*", "†")
    var content: String        // The footnote content text
    var refId: String          // The ID used in the EPUB for linking (e.g., "note1")
    var sourceBlockId: Int     // Block number [N] containing the footnote reference

    static let databaseTableName = "footnotes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Column Definitions

extension Footnote {
    enum Columns: String, ColumnExpression {
        case id, chapterId, marker, content, refId, sourceBlockId
    }
}
