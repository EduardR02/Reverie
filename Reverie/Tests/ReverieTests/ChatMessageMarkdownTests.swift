import XCTest
@testable import Reverie

final class ChatMessageMarkdownTests: XCTestCase {

    // MARK: - shouldRenderMarkdown

    func testUserMessageNeverRendersMarkdown() {
        let message = ChatMessage(role: .user, content: "Hello world", isStreaming: false)
        XCTAssertFalse(message.shouldRenderMarkdown)
    }

    func testReferenceMessageNeverRendersMarkdown() {
        let message = ChatMessage(role: .reference, content: "Hello world", isStreaming: false)
        XCTAssertFalse(message.shouldRenderMarkdown)
    }


    func testStreamingMessageTransitionsToNonStreaming() {
        var message = ChatMessage(role: .assistant, content: "Partial", isStreaming: true)
        XCTAssertFalse(message.shouldRenderMarkdown)

        message.isStreaming = false
        XCTAssertTrue(message.shouldRenderMarkdown)
    }

    func testEmptyStreamingMessageDoesNotRenderMarkdown() {
        let message = ChatMessage(role: .assistant, content: "", isStreaming: true)
        XCTAssertFalse(message.shouldRenderMarkdown)
    }
}
