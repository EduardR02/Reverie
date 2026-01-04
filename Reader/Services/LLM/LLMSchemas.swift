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
            "content": JSONSchemaBuilder.string(description: "Substantive explanation with specifics."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "Block number [N] this relates to.")
        ],
        required: ["type", "title", "content", "sourceBlockId"]
    )

    private static let quizQuestion = JSONSchemaBuilder.object(
        properties: [
            "question": JSONSchemaBuilder.string(description: "Question testing understanding, not trivia."),
            "answer": JSONSchemaBuilder.string(description: "Complete answer with reasoning."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "Block number [N] containing the answer.")
        ],
        required: ["question", "answer", "sourceBlockId"]
    )

    private static let imageSuggestion = JSONSchemaBuilder.object(
        properties: [
            "excerpt": JSONSchemaBuilder.string(description: "Verbatim excerpt that captures the scene to visualize."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "Block number [N] where the excerpt starts.")
        ],
        required: ["excerpt", "sourceBlockId"]
    )

    static func chapterAnalysis(imagesEnabled: Bool) -> LLMStructuredSchema {
        var properties: [String: Any] = [
            "annotations": JSONSchemaBuilder.array(items: annotation, description: "Chapter insights."),
            "quizQuestions": JSONSchemaBuilder.array(items: quizQuestion, description: "Quiz questions."),
            "summary": JSONSchemaBuilder.string(description: "2-3 sentence summary.")
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
