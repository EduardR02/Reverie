import XCTest
@testable import Reverie

final class ChapterAnalysisValidationTests: XCTestCase {
    @MainActor
    func testRejectsUnknownCategoryAndNonexistentAnchorRatherThanRelocating() throws {
        let blocks = ContentBlockParser().parse(html: "<p>The telescope tracked a moving star.</p>").blocks
        for annotation in [
            LLMService.AnnotationData(type: "invented", title: "Title", content: "Explanation", sourceBlockId: 1),
            LLMService.AnnotationData(type: "science", title: "Title", content: "Explanation", sourceBlockId: 0),
            LLMService.AnnotationData(type: "science", title: "Title", content: "Explanation", sourceBlockId: 2)
        ] {
            XCTAssertThrowsError(try LLMService.ChapterAnalysis(annotations: [annotation]).validated(blocks: blocks))
        }
    }

    @MainActor
    func testRejectsBlankSubstantiveFieldsAndUngroundedQuiz() throws {
        let blocks = ContentBlockParser().parse(html: "<p>The experiment failed because the seal leaked.</p>").blocks
        let invalid = [
            LLMService.ChapterAnalysis(annotations: [.init(type: "science", title: " \n", content: "Explanation", sourceBlockId: 1)]),
            LLMService.ChapterAnalysis(annotations: [.init(type: "science", title: "Title", content: "\t", sourceBlockId: 1)]),
            LLMService.ChapterAnalysis(quizQuestions: [.init(question: "Why?", answer: "\n", sourceBlockId: 1)]),
            LLMService.ChapterAnalysis(quizQuestions: [.init(question: "Why?", answer: "The seal leaked.", sourceBlockId: 99)])
        ]
        for analysis in invalid {
            XCTAssertThrowsError(try analysis.validated(blocks: blocks))
        }
    }

    @MainActor
    func testVerbatimImageMayCrossAdjacentBlocksWithWhitespaceNormalization() throws {
        let blocks = ContentBlockParser().parse(html: "<p>The river shone at dawn.</p><p>A narrow bridge crossed it.</p>").blocks
        let analysis = LLMService.ChapterAnalysis(imageSuggestions: [
            .init(excerpt: "shone at dawn.\n\nA narrow bridge", sourceBlockId: 1, aspectRatio: "16:9")
        ])
        let validated = try analysis.validated(blocks: blocks)
        XCTAssertEqual(validated.imageSuggestions.count, 1)
        XCTAssertEqual(validated.imageSuggestions[0].sourceBlockId, 1)
        XCTAssertEqual(validated.imageSuggestions[0].aspectRatio, "16:9")
    }

    @MainActor
    func testRejectsInventedStitchedAndWrongStartImageExcerpts() throws {
        let blocks = ContentBlockParser().parse(html: "<p>The river shone at dawn.</p><p>They stopped to rest.</p><p>A narrow bridge crossed it.</p>").blocks
        for suggestion in [
            LLMService.ImageSuggestion(excerpt: "The river sparkled at dawn.", sourceBlockId: 1),
            LLMService.ImageSuggestion(excerpt: "shone at dawn. A narrow bridge", sourceBlockId: 1),
            LLMService.ImageSuggestion(excerpt: "A narrow bridge crossed it.", sourceBlockId: 1),
            LLMService.ImageSuggestion(excerpt: "The river shone at dawn.", sourceBlockId: 3)
        ] {
            XCTAssertThrowsError(try LLMService.ChapterAnalysis(imageSuggestions: [suggestion]).validated(blocks: blocks))
        }
    }

    @MainActor
    func testRemovesExactDuplicatesWithoutDiscardingDistinctIdeasAtSameAnchor() throws {
        let blocks = ContentBlockParser().parse(html: "<p>The river shone at dawn.</p>").blocks
        let first = LLMService.AnnotationData(type: "science", title: "Reflection", content: "A specific explanation.", sourceBlockId: 1)
        let different = LLMService.AnnotationData(type: "history", title: "River transport", content: "A different explanation.", sourceBlockId: 1)
        let question = LLMService.QuizData(question: "Why did it shine?", answer: "Light was reflected.", sourceBlockId: 1)
        let analysis = LLMService.ChapterAnalysis(
            annotations: [first, first, different],
            quizQuestions: [question, question],
            imageSuggestions: [
                .init(excerpt: "The river shone at dawn.", sourceBlockId: 1),
                .init(excerpt: "The river\nshone at dawn.", sourceBlockId: 1)
            ]
        )
        let validated = try analysis.validated(blocks: blocks)
        XCTAssertEqual(validated.annotations.map(\.title), ["Reflection", "River transport"])
        XCTAssertEqual(validated.quizQuestions.count, 1)
        XCTAssertEqual(validated.imageSuggestions.count, 1)
    }

    @MainActor
    func testEmptyAdditionalResultsAreValidWithoutSummaryOrInventedMinimum() throws {
        let validated = try LLMService.ChapterAnalysis().validated(blocks: [])
        XCTAssertTrue(validated.annotations.isEmpty)
        XCTAssertTrue(validated.quizQuestions.isEmpty)
        XCTAssertTrue(validated.imageSuggestions.isEmpty)
        XCTAssertEqual(validated.summary, "")
        for density in DensityLevel.allCases {
            XCTAssertEqual(density.suggestedInsightLimit(wordCount: 0), 0)
            XCTAssertEqual(density.suggestedInsightLimit(wordCount: 1), 1)
        }
    }
}
