import Foundation

struct LLMStructuredSchema {
    let name: String
    let schema: [String: Any]
}

enum JSONSchemaBuilder {
    static func string(description: String? = nil, enumValues: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string"]
        if let description {
            schema["description"] = description
        }
        if let enumValues {
            schema["enum"] = enumValues
        }
        return schema
    }

    static func integer(description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer"]
        if let description {
            schema["description"] = description
        }
        return schema
    }

    static func array(items: [String: Any], description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "array", "items": items]
        if let description {
            schema["description"] = description
        }
        return schema
    }

    static func object(properties: [String: Any], required: [String], description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
        if let description {
            schema["description"] = description
        }
        return schema
    }
}

@MainActor
enum SchemaLibrary {
    private static let annotation = JSONSchemaBuilder.object(
        properties: [
            "type": JSONSchemaBuilder.string(
                description: "Insight category.",
                enumValues: ["science", "history", "philosophy", "connection", "world"]
            ),
            "title": JSONSchemaBuilder.string(description: "Compelling title hinting at the discovery."),
            "content": JSONSchemaBuilder.string(description: "Substantive explanation connecting a specific passage to reliable external knowledge; distinguish fact, analogy, and interpretation. No invented citations or later-story spoilers."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "An actual supplied block number [N] where the supporting passage has appeared.")
        ],
        required: ["type", "title", "content", "sourceBlockId"]
    )

    private static let quizQuestion = JSONSchemaBuilder.object(
        properties: [
            "question": JSONSchemaBuilder.string(description: "Question testing understanding, not trivia."),
            "answer": JSONSchemaBuilder.string(description: "Complete answer with reasoning."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "An actual supplied block number [N] by which the question can be answered, without later-block spoilers.")
        ],
        required: ["question", "answer", "sourceBlockId"]
    )

    private static let imageSuggestion = JSONSchemaBuilder.object(
        properties: [
            "excerpt": JSONSchemaBuilder.string(description: "Verbatim contiguous chapter text, without block labels, invented words, or stitched-together passages."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "Actual supplied block number [N] where the verbatim excerpt starts."),
            "aspectRatio": JSONSchemaBuilder.string(
                description: "Best framing for the scene. Must be one of 16:9, 1:1, or 9:16.",
                enumValues: ["16:9", "1:1", "9:16"]
            )
        ],
        required: ["excerpt", "sourceBlockId", "aspectRatio"]
    )

    static func chapterAnalysis(imagesEnabled: Bool) -> LLMStructuredSchema {
        var properties: [String: Any] = [
            "annotations": JSONSchemaBuilder.array(items: annotation, description: "Chapter insights."),
            "quizQuestions": JSONSchemaBuilder.array(items: quizQuestion, description: "Quiz questions."),
            "summary": JSONSchemaBuilder.string(description: "Chapter-only continuity record, up to roughly 300 words as needed; preserve consequential facts, reasoning, names, constraints, and uncertainty.")
        ]
        
        var required = ["annotations", "quizQuestions", "summary"]
        
        if imagesEnabled {
            properties["imageSuggestions"] = JSONSchemaBuilder.array(items: imageSuggestion, description: "Image excerpts.")
            required.append("imageSuggestions")
        }
        
        return LLMStructuredSchema(
            name: "chapter_analysis",
            schema: JSONSchemaBuilder.object(
                properties: properties,
                required: required
            )
        )
    }

    static let annotationsOnly = LLMStructuredSchema(
        name: "annotations",
        schema: JSONSchemaBuilder.object(
            properties: [
                "annotations": JSONSchemaBuilder.array(items: annotation, description: "Additional insights.")
            ],
            required: ["annotations"]
        )
    )

    static let quizOnly = LLMStructuredSchema(
        name: "quiz_questions",
        schema: JSONSchemaBuilder.object(
            properties: [
                "quizQuestions": JSONSchemaBuilder.array(items: quizQuestion, description: "Additional questions.")
            ],
            required: ["quizQuestions"]
        )
    )

    static let summaryOnly = LLMStructuredSchema(
        name: "chapter_summary",
        schema: JSONSchemaBuilder.object(
            properties: [
                "summary": JSONSchemaBuilder.string(description: "Chapter-only continuity record, up to roughly 300 words as needed, preserving consequential details and uncertainty rather than a plot blurb.")
            ],
            required: ["summary"]
        )
    )

    static let chapterClassification = LLMStructuredSchema(
        name: "chapter_classification",
        schema: JSONSchemaBuilder.object(
            properties: [
                "classifications": JSONSchemaBuilder.array(
                    items: JSONSchemaBuilder.object(
                        properties: [
                            "index": JSONSchemaBuilder.integer(description: "Chapter index."),
                            "type": JSONSchemaBuilder.string(
                                description: "content or garbage.",
                                enumValues: ["content", "garbage"]
                            )
                        ],
                        required: ["index", "type"]
                    ),
                    description: "Chapter classifications."
                )
            ],
            required: ["classifications"]
        )
    )
}

enum ChapterAnalysisValidationError: LocalizedError {
    case invalidAnchor(kind: String, blockID: Int)
    case unknownCategory(String)
    case emptyField(String)
    case ungroundedImage(blockID: Int)
    case missingCompletion

    var errorDescription: String? {
        switch self {
        case .invalidAnchor(let kind, let blockID):
            return "The generated \(kind) refers to nonexistent block \(blockID)."
        case .unknownCategory(let category):
            return "The generated insight has an unknown category: \(category)."
        case .emptyField(let field):
            return "The generated chapter analysis has an empty \(field)."
        case .ungroundedImage(let blockID):
            return "The generated image excerpt is not contiguous chapter text starting in block \(blockID)."
        case .missingCompletion:
            return "Chapter analysis ended without a complete result."
        }
    }
}

extension LLMService.ChapterAnalysis {
    /// JSON schemas guarantee shape, not valid anchors or grounded quotations.
    /// Validate before any persistence or paid image-generation side effects.
    func validated(blocks: [ContentBlock]) throws -> Self {
        let blockIDs = Set(blocks.map(\.id))
        let categories: Set<String> = ["science", "history", "philosophy", "connection", "world"]

        func requireAnchor(_ blockID: Int, kind: String) throws {
            guard blockIDs.contains(blockID) else {
                throw ChapterAnalysisValidationError.invalidAnchor(kind: kind, blockID: blockID)
            }
        }

        func requireText(_ text: String, field: String) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChapterAnalysisValidationError.emptyField(field)
            }
        }

        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        var result = self
        var annotationKeys = Set<[String]>()
        result.annotations = try annotations.filter { annotation in
            guard categories.contains(annotation.type) else {
                throw ChapterAnalysisValidationError.unknownCategory(annotation.type)
            }
            try requireAnchor(annotation.sourceBlockId, kind: "insight")
            try requireText(annotation.title, field: "insight title")
            try requireText(annotation.content, field: "insight content")
            return annotationKeys.insert([
                annotation.type, normalized(annotation.title), normalized(annotation.content)
            ]).inserted
        }

        var questionKeys = Set<[String]>()
        result.quizQuestions = try quizQuestions.filter { question in
            try requireAnchor(question.sourceBlockId, kind: "quiz question")
            try requireText(question.question, field: "quiz question")
            try requireText(question.answer, field: "quiz answer")
            return questionKeys.insert([normalized(question.question), normalized(question.answer)]).inserted
        }

        if !imageSuggestions.isEmpty {
            let blockTexts = blocks.map { normalized($0.text) }
            let chapterText = blockTexts.joined(separator: " ")
            var blockRanges: [Int: Range<String.Index>] = [:]
            var cursor = chapterText.startIndex
            for (block, text) in zip(blocks, blockTexts) {
                let end = chapterText.index(cursor, offsetBy: text.count)
                blockRanges[block.id] = cursor..<end
                cursor = end == chapterText.endIndex ? end : chapterText.index(after: end)
            }

            var imageKeys = Set<String>()
            result.imageSuggestions = try imageSuggestions.filter { suggestion in
                try requireAnchor(suggestion.sourceBlockId, kind: "image")
                try requireText(suggestion.excerpt, field: "image excerpt")
                let excerpt = normalized(suggestion.excerpt)
                guard let blockRange = blockRanges[suggestion.sourceBlockId],
                      let match = chapterText.range(of: excerpt, range: blockRange.lowerBound..<chapterText.endIndex),
                      match.lowerBound < blockRange.upperBound else {
                    throw ChapterAnalysisValidationError.ungroundedImage(blockID: suggestion.sourceBlockId)
                }
                return imageKeys.insert(excerpt).inserted
            }
        }
        return result
    }
}
