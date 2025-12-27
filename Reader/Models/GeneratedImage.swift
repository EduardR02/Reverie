import Foundation
import GRDB

struct GeneratedImage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var chapterId: Int64
    var prompt: String
    var imagePath: String
    var sourceOffset: Int
    var createdAt: Date = Date()

    static let databaseTableName = "generated_images"

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
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
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let chapterId = Column(CodingKeys.chapterId)
        static let prompt = Column(CodingKeys.prompt)
        static let imagePath = Column(CodingKeys.imagePath)
        static let sourceOffset = Column(CodingKeys.sourceOffset)
        static let createdAt = Column(CodingKeys.createdAt)
    }
}
