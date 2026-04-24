import XCTest
@testable import Reverie

final class ChatMessageMarkdownTests: XCTestCase {

    // MARK: - shouldRenderMarkdown

    func testAssistantMessageRendersMarkdownWhenNotStreaming() {
        let message = ChatMessage(role: .assistant, content: "Hello **world**", isStreaming: false)
        XCTAssertTrue(message.shouldRenderMarkdown)
    }

    func testAssistantMessageDoesNotRenderMarkdownWhenStreaming() {
        let message = ChatMessage(role: .assistant, content: "Hello **world**", isStreaming: true)
        XCTAssertFalse(message.shouldRenderMarkdown)
    }

    func testUserMessageNeverRendersMarkdown() {
        let message = ChatMessage(role: .user, content: "Hello world", isStreaming: false)
        XCTAssertFalse(message.shouldRenderMarkdown)
    }

    func testReferenceMessageNeverRendersMarkdown() {
        let message = ChatMessage(role: .reference, content: "Hello world", isStreaming: false)
        XCTAssertFalse(message.shouldRenderMarkdown)
    }

    func testAssistantDefaultsToNotStreaming() {
        let message = ChatMessage(role: .assistant, content: "Hello")
        XCTAssertFalse(message.isStreaming,
                       "Default init should have isStreaming = false")
    }

    func testAssistantDefaultsToNotStreamingExplicit() {
        let message = ChatMessage(role: .assistant, content: "Hello")
        XCTAssertTrue(message.shouldRenderMarkdown,
                       "Default assistant message should render markdown")
    }

    // MARK: - isStreaming lifecycle (conceptual validation)

    func testStreamingMessageTransitionsToNonStreaming() {
        var message = ChatMessage(role: .assistant, content: "Partial", isStreaming: true)
        XCTAssertFalse(message.shouldRenderMarkdown)

        message.isStreaming = false
        XCTAssertTrue(message.shouldRenderMarkdown)
    }

    func testStreamingFlagIndependentOfContent() {
        let empty = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let partial = ChatMessage(role: .assistant, content: "Partial", isStreaming: true)
        let full = ChatMessage(role: .assistant, content: "Full **bold** text", isStreaming: false)

        // Content doesn't affect shouldRenderMarkdown — only role + streaming state
        XCTAssertFalse(empty.shouldRenderMarkdown)
        XCTAssertFalse(partial.shouldRenderMarkdown)
        XCTAssertTrue(full.shouldRenderMarkdown)
    }
}
