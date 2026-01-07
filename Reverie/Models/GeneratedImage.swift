import Foundation
import GRDB

struct GeneratedImage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: Int64?
    var chapterId: Int64
    var prompt: String
    var imagePath: String
    var sourceBlockId: Int  // Block number [N] this image depicts
    var createdAt: Date = Date()

    static let databaseTableName = "generated_images"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Computed

    var imageURL: URL {
        URL(fileURLWithPath: imagePath)
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Column Definitions

extension GeneratedImage {
    enum Columns: String, ColumnExpression {
        case id, chapterId, prompt, imagePath, sourceBlockId, createdAt
    }
}
