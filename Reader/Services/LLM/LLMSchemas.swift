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
            "prompt": JSONSchemaBuilder.string(description: "Vivid image generation prompt."),
            "sourceBlockId": JSONSchemaBuilder.integer(description: "Block number [N] this depicts.")
        ],
        required: ["prompt", "sourceBlockId"]
    )

    static let chapterAnalysis = LLMStructuredSchema(
        name: "chapter_analysis",
        schema: JSONSchemaBuilder.object(
            properties: [
                "annotations": JSONSchemaBuilder.array(items: annotation, description: "Chapter insights."),
                "quizQuestions": JSONSchemaBuilder.array(items: quizQuestion, description: "Quiz questions."),
                "imageSuggestions": JSONSchemaBuilder.array(items: imageSuggestion, description: "Image prompts."),
                "summary": JSONSchemaBuilder.string(description: "2-3 sentence summary.")
            ],
            required: ["annotations", "quizQuestions", "imageSuggestions", "summary"]
        )
    )

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
