import XCTest
@testable import Reverie

final class LLMPromptsTests: XCTestCase {
    @MainActor
    func testChatKeepsNativeRolesAndAppendsCurrentTurnExactlyOnce() {
        let opaqueState = LLMConversationState(
            provider: .google,
            model: "provider-model",
            payload: Data(#"[{"thoughtSignature":"opaque-provider-state"}]"#.utf8)
        )
        let history = [
            LLMService.ChatTurn(role: .user, content: "Who is speaking?"),
            LLMService.ChatTurn(role: .assistant, content: "The captain is speaking.", providerState: opaqueState)
        ]
        let prompt = PromptLibrary.chatPrompt(
            message: "How does that change the scene?",
            previousTurns: history,
            referenceTitle: "Navigation insight",
            referenceContent: "The star chart implies a prior expedition.",
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: "Earlier summary"
        )
        XCTAssertEqual(prompt.conversation, history + [
            LLMService.ChatTurn(role: .user, content: "How does that change the scene?")
        ])
        for turn in prompt.conversation {
            XCTAssertFalse(prompt.text.contains(turn.content), "Conversation belongs in native provider turns, not flattened cached context")
        }
    }

    @MainActor
    func testChatCachePrefixDoesNotChangeWhenConversationGrows() {
        let first = PromptLibrary.chatPrompt(
            message: "First question", contentWithBlocks: "[1] Chapter text", rollingSummary: "Earlier summary"
        )
        let next = PromptLibrary.chatPrompt(
            message: "Follow-up question",
            previousTurns: [.init(role: .user, content: "First question"), .init(role: .assistant, content: "First answer")],
            contentWithBlocks: "[1] Chapter text",
            rollingSummary: "Earlier summary"
        )
        XCTAssertNotNil(first.cachePrefix)
        XCTAssertEqual(first.cachePrefix, next.cachePrefix)
        XCTAssertEqual(first.conversation.count, 1)
        XCTAssertEqual(next.conversation.count, 3)
    }

    @MainActor
    func testAdditionalGenerationCachesSourceNotChangingExclusionLists() {
        let firstInsights = PromptLibrary.moreInsightsPrompt(
            contentWithBlocks: "[1] A passage", rollingSummary: "Earlier summary", existingTitles: [], insightDensity: .medium
        )
        let nextInsights = PromptLibrary.moreInsightsPrompt(
            contentWithBlocks: "[1] A passage", rollingSummary: "Earlier summary", existingTitles: ["Already covered"], insightDensity: .medium
        )
        XCTAssertEqual(firstInsights.cachePrefix, nextInsights.cachePrefix)
        XCTAssertNotEqual(firstInsights.cacheSuffix, nextInsights.cacheSuffix)
        XCTAssertEqual(nextInsights.text, (nextInsights.cachePrefix ?? "") + (nextInsights.cacheSuffix ?? ""))

        let firstQuiz = PromptLibrary.moreQuestionsPrompt(
            contentWithBlocks: "[1] A passage", rollingSummary: "Earlier summary", existingQuestions: []
        )
        let nextQuiz = PromptLibrary.moreQuestionsPrompt(
            contentWithBlocks: "[1] A passage", rollingSummary: "Earlier summary", existingQuestions: ["Already asked?"]
        )

        XCTAssertEqual(firstQuiz.cachePrefix, nextQuiz.cachePrefix)
        XCTAssertNotEqual(firstQuiz.cacheSuffix, nextQuiz.cacheSuffix)
    }
    @MainActor
    func testAnalysisCachesInstructionsAcrossDifferentChapters() {
        let first = PromptLibrary.analysisPrompt(
            contentWithBlocks: "[1] First chapter", rollingSummary: nil,
            bookTitle: "Book", author: "Author", insightDensity: .medium, imageDensity: nil, wordCount: 500
        )
        let second = PromptLibrary.analysisPrompt(
            contentWithBlocks: "[1] Second chapter", rollingSummary: "First chapter summary",
            bookTitle: "Book", author: "Author", insightDensity: .medium, imageDensity: nil, wordCount: 2000
        )
        XCTAssertNotNil(first.cachePrefix)
        XCTAssertEqual(first.cachePrefix, second.cachePrefix)
        XCTAssertNotEqual(first.cacheSuffix, second.cacheSuffix)
        XCTAssertEqual(second.text, (second.cachePrefix ?? "") + (second.cacheSuffix ?? ""))
    }
}
