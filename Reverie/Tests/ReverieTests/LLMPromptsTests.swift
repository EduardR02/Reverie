import XCTest
@testable import Reverie

final class LLMPromptsTests: XCTestCase {
    
    func testAnalysisPromptIncludesMetadata() {
        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: "[1] Test content",
            rollingSummary: nil,
            bookTitle: "Neuromancer",
            author: "William Gibson",
            insightDensity: .medium,
            imageDensity: nil,
            wordCount: 1000
        )
        
        XCTAssertTrue(prompt.text.contains("[Book context: \"Neuromancer\" by William Gibson"))
        XCTAssertTrue(prompt.text.contains("do not force connections"))
    }
    
    func testAnalysisPromptHandlesMissingAuthor() {
        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: "[1] Test content",
            rollingSummary: nil,
            bookTitle: "Neuromancer",
            author: nil,
            insightDensity: .medium,
            imageDensity: nil,
            wordCount: 1000
        )
        
        XCTAssertTrue(prompt.text.contains("[Book context: \"Neuromancer\"]"))
        XCTAssertFalse(prompt.text.contains("\"Neuromancer\" by "))
    }
    
    func testAnalysisPromptOmitsMetadataWhenNoTitle() {
        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: "[1] Test content",
            rollingSummary: nil,
            bookTitle: nil,
            author: "William Gibson",
            insightDensity: .medium,
            imageDensity: nil,
            wordCount: 1000
        )
        
        XCTAssertFalse(prompt.text.contains("[Book context:"))
    }

    func testAnalysisPromptIncludesImageAspectRatioGuidance() {
        let prompt = PromptLibrary.analysisPrompt(
            contentWithBlocks: "[1] Test content",
            rollingSummary: nil,
            bookTitle: nil,
            author: nil,
            insightDensity: .medium,
            imageDensity: .medium,
            wordCount: 1000
        )

        XCTAssertTrue(prompt.text.contains("aspectRatio: choose exactly one of 16:9, 1:1, or 9:16"))
    }

    func testChatPromptIncludesPreviousTurnsRoleAware() {
        let prompt = PromptLibrary.chatPrompt(
            message: "How does that change the scene?",
            previousTurns: [
                LLMService.ChatTurn(role: .user, content: "Who is speaking?"),
                LLMService.ChatTurn(role: .assistant, content: "The captain is speaking.")
            ],
            referenceTitle: "Navigation insight",
            referenceContent: "The star chart implies a prior expedition.",
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: "Earlier summary"
        )

        XCTAssertTrue(prompt.text.contains("Story so far: Earlier summary"))
        XCTAssertTrue(prompt.text.contains("[User]\nWho is speaking?"))
        XCTAssertTrue(prompt.text.contains("[Assistant]\nThe captain is speaking."))
        XCTAssertTrue(prompt.text.contains("Insight the reader is asking from:"))
        XCTAssertTrue(prompt.text.contains("Title: Navigation insight"))
        XCTAssertTrue(prompt.text.contains("Current reader question:"))
        XCTAssertTrue(prompt.text.contains("[User]\nHow does that change the scene?"))
        XCTAssertTrue(prompt.text.contains("No spoilers beyond this chapter."))
    }
}
