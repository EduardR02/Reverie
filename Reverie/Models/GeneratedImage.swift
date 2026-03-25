import Foundation
import GRDB

struct GeneratedImage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    enum Status: String, Codable {
        case success
        case failed
        case refused
    }

    var id: Int64?
    var chapterId: Int64
    var excerpt: String
    var prompt: String
    var imagePath: String
    var sourceBlockId: Int  // Block number [N] this image depicts
    var aspectRatio: String?
    var status: Status = .success
    var failureReason: String?
    var createdAt: Date = Date()

    static let databaseTableName = "generated_images"

    init(
        id: Int64? = nil,
        chapterId: Int64,
        excerpt: String? = nil,
        prompt: String,
        imagePath: String,
        sourceBlockId: Int,
        aspectRatio: String? = nil,
        status: Status = .success,
        failureReason: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.chapterId = chapterId
        self.excerpt = excerpt ?? prompt
        self.prompt = prompt
        self.imagePath = imagePath
        self.sourceBlockId = sourceBlockId
        self.aspectRatio = aspectRatio
        self.status = status
        self.failureReason = failureReason
        self.createdAt = createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Computed

    var imageURL: URL {
        URL(fileURLWithPath: imagePath)
    }

    var isSuccess: Bool {
        status == .success
    }

    var displayExcerpt: String {
        excerpt.isEmpty ? prompt : excerpt
    }

    // MARK: - Relationships

    static let chapter = belongsTo(Chapter.self)
}

// MARK: - Column Definitions

extension GeneratedImage {
    enum Columns: String, ColumnExpression {
        case id, chapterId, excerpt, prompt, imagePath, sourceBlockId, aspectRatio, status, failureReason, createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case chapterId
        case excerpt
        case prompt
        case imagePath
        case sourceBlockId
        case aspectRatio
        case status
        case failureReason
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        chapterId = try container.decode(Int64.self, forKey: .chapterId)
        prompt = try container.decode(String.self, forKey: .prompt)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? prompt
        imagePath = try container.decode(String.self, forKey: .imagePath)
        sourceBlockId = try container.decode(Int.self, forKey: .sourceBlockId)
        aspectRatio = try container.decodeIfPresent(String.self, forKey: .aspectRatio)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .success
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
