import Foundation
import GRDB

struct Footnote: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var chapterId: Int64
    var marker: String         // The footnote reference marker (e.g., "1", "*", "†")
    var content: String        // The footnote content text
    var refId: String          // The ID used in the EPUB for linking (e.g., "note1")
    var sourceOffset: Int      // Position in chapter where the footnote reference appears

    static let databaseTableName = "footnotes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Column Definitions

extension Footnote {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let chapterId = Column(CodingKeys.chapterId)
        static let marker = Column(CodingKeys.marker)
        static let content = Column(CodingKeys.content)
        static let refId = Column(CodingKeys.refId)
        static let sourceOffset = Column(CodingKeys.sourceOffset)
    }
}
