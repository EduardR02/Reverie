import XCTest
@testable import Reverie

@MainActor
final class ReaderChatLifecycleTests: XCTestCase {
    func testCancellationBeforeRequestStartsNeverCallsProviderAndStopsLoading() async throws {
        let session = ReaderChatSession()
        let stub = ReaderChatStreamStub()
        session.send("Question", makeStream: stub.makeStream)
        let running = try XCTUnwrap(session.task)
        session.cancel()
        await running.value
        XCTAssertFalse(stub.started)
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.task)
        let response = try XCTUnwrap(session.messages.last)
        XCTAssertFalse(response.isStreaming)
        XCTAssertTrue(response.isError)
        XCTAssertFalse(response.content.isEmpty)
        XCTAssertNil(response.providerState)
    }

    func testResetCancelsProducerAndRejectsLateTextAndNativeState() async throws {
        let session = ReaderChatSession()
        let old = ReaderChatStreamStub()
        session.send("Old question", makeStream: old.makeStream)
        let running = try XCTUnwrap(session.task)
        await old.waitUntilStarted()
        session.reset()
        await running.value
        await old.waitUntilTerminated()
        XCTAssertTrue(old.wasCancelled)
        XCTAssertFalse(session.isLoading)
        XCTAssertTrue(session.messages.isEmpty)

        session.send("New question") { turns, _ in
            XCTAssertTrue(turns.isEmpty)
            old.onProviderState?(Self.state)
            old.continuation.yield(.content("Stale answer"))
            return AsyncThrowingStream { continuation in
                continuation.yield(.content("Fresh answer"))
                continuation.finish()
            }
        }
        await session.task?.value
        XCTAssertEqual(session.messages.map(\.content), ["New question", "Fresh answer"])
        XCTAssertNil(session.messages.last?.providerState)
        XCTAssertFalse(session.isLoading)
    }

    func testDisappearingChatCanResumeWithoutReplayingInterruptedNativeState() async throws {
        let session = ReaderChatSession()
        let stub = ReaderChatStreamStub()
        session.send("Interrupted question", makeStream: stub.makeStream)
        let running = try XCTUnwrap(session.task)
        await stub.waitUntilStarted()
        stub.onProviderState?(Self.state)
        session.cancel()
        await running.value
        await stub.waitUntilTerminated()
        XCTAssertTrue(stub.wasCancelled)
        XCTAssertNil(session.messages.last?.providerState)
        XCTAssertFalse(session.messages.last?.isStreaming ?? true)
        session.send("Try again") { turns, _ in
            XCTAssertFalse(turns.contains { $0.role == .assistant })
            XCTAssertTrue(turns.allSatisfy { $0.providerState == nil })
            return Self.completed("A complete answer")
        }
        await session.task?.value
        XCTAssertEqual(session.messages.last?.content, "A complete answer")
        XCTAssertFalse(session.messages.last?.isError ?? true)
    }

    func testSuccessfulTurnsPreserveNativeStateButNeverReplayDisplayedThinking() async throws {
        let session = ReaderChatSession()
        session.send("First question") { turns, saveState in
            XCTAssertTrue(turns.isEmpty)
            saveState(Self.state)
            return AsyncThrowingStream { continuation in
                continuation.yield(.thinking("Displayed summary, not replayable reasoning"))
                continuation.yield(.content("First answer"))
                continuation.finish()
            }
        }
        await session.task?.value
        XCTAssertEqual(session.messages.last?.thinking, "Displayed summary, not replayable reasoning")
        session.send("Follow-up") { turns, _ in
            XCTAssertEqual(turns.map(\.content), ["First question", "First answer"])
            XCTAssertEqual(turns.last?.providerState, Self.state)
            return Self.completed("Second answer")
        }
        await session.task?.value
        XCTAssertEqual(session.messages.map(\.content), ["First question", "First answer", "Follow-up", "Second answer"])
    }

    func testFailedResponseNeverReplaysItsNativeStateAndAllowsAnotherRequest() async throws {
        let session = ReaderChatSession()
        session.send("Question") { _, saveState in
            saveState(Self.state)
            return AsyncThrowingStream { continuation in
                continuation.yield(.content("Partial response"))
                continuation.finish(throwing: ReaderChatTestError.failed)
            }
        }
        await session.task?.value
        XCTAssertTrue(session.messages.last?.isError ?? false)
        XCTAssertNil(session.messages.last?.providerState)
        XCTAssertFalse(session.isLoading)
        session.send("Retry") { turns, _ in
            XCTAssertFalse(turns.contains { $0.role == .assistant })
            return Self.completed("Recovered")
        }
        await session.task?.value
        XCTAssertEqual(session.messages.last?.content, "Recovered")
    }

    func testChapterReferenceProviderModelCredentialAndSessionChangesResetConversation() async throws {
        let base = Self.configuration()
        let variants = [
            Self.configuration(chapterID: 2),
            Self.configuration(reference: .init(title: "A different insight", content: "Different context", type: nil)),
            Self.configuration(provider: .anthropic),
            Self.configuration(model: "different-model"),
            Self.configuration(apiKey: "different-fixture-key"),
            Self.configuration(mode: .chatGPTSubscription),
            Self.configuration(subscriptionRevision: 1),
            Self.configuration(chapterContent: "Changed chapter content"),
            Self.configuration(rollingSummary: "New summary")
        ]
        for configuration in variants {
            let session = ReaderChatSession()
            let stub = ReaderChatStreamStub()
            session.configure(base)
            session.send("Old question", makeStream: stub.makeStream)
            let running = try XCTUnwrap(session.task)
            await stub.waitUntilStarted()
            stub.onProviderState?(Self.state)
            session.configure(configuration)
            await running.value
            XCTAssertFalse(session.isLoading)
            XCTAssertTrue(session.messages.isEmpty)
            session.send("New context") { turns, _ in
                XCTAssertTrue(turns.isEmpty)
                stub.onProviderState?(Self.state)
                return Self.completed("Fresh answer")
            }
            await session.task?.value
            XCTAssertNil(session.messages.last?.providerState)
            XCTAssertEqual(session.messages.map(\.content), ["New context", "Fresh answer"])
        }
    }

    func testUnchangedConfigurationDoesNotInterruptActiveRequest() async throws {
        let session = ReaderChatSession()
        let configuration = Self.configuration()
        let stub = ReaderChatStreamStub()
        session.configure(configuration)
        session.send("Question", makeStream: stub.makeStream)
        let running = try XCTUnwrap(session.task)
        await stub.waitUntilStarted()
        session.configure(configuration)
        XCTAssertTrue(session.isLoading)
        stub.continuation.yield(.content("Answer"))
        stub.continuation.finish()
        await running.value
        XCTAssertEqual(session.messages.last?.content, "Answer")
        XCTAssertFalse(session.messages.last?.isError ?? true)
    }

    private static var state: LLMConversationState {
        LLMConversationState(provider: .openai, model: "fixture-model", payload: Data("[]".utf8))
    }

    private static func completed(_ text: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.content(text))
            continuation.finish()
        }
    }

    private static func configuration(
        chapterID: Int64 = 1, provider: LLMProvider = .openai, model: String = "fixture-model",
        mode: OpenAIAuthenticationMode = .apiKey, apiKey: String = "fixture-key", reference: AppState.ChatReference? = nil,
        subscriptionRevision: UInt64 = 0, chapterContent: String? = nil, rollingSummary: String? = nil
    ) -> ReaderChatConfiguration {
        ReaderChatConfiguration(chapterID: chapterID, chapterContent: chapterContent, rollingSummary: rollingSummary, provider: provider, model: model, authenticationMode: mode, apiKey: apiKey, reference: reference, subscriptionRevision: subscriptionRevision)
    }
}

private enum ReaderChatTestError: LocalizedError {
    case failed
    var errorDescription: String? { "The fixture response failed." }
}

@MainActor
private final class ReaderChatStreamStub {
    let stream: AsyncThrowingStream<LLMStreamChunk, Error>
    let continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    private(set) var started = false
    private(set) var wasCancelled = false
    var onProviderState: (@MainActor (LLMConversationState) -> Void)?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var terminationWaiter: CheckedContinuation<Void, Never>?
    private var terminated = false

    init() {
        let pair = AsyncThrowingStream<LLMStreamChunk, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [weak self] termination in
            Task { @MainActor in
                guard let self else { return }
                if case .cancelled = termination { self.wasCancelled = true }
                self.terminated = true
                self.terminationWaiter?.resume()
                self.terminationWaiter = nil
            }
        }
    }

    func makeStream(_ turns: [LLMService.ChatTurn], _ saveState: @escaping @MainActor (LLMConversationState) -> Void) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        started = true
        onProviderState = saveState
        startWaiter?.resume()
        startWaiter = nil
        return stream
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func waitUntilTerminated() async {
        if !terminated { await withCheckedContinuation { terminationWaiter = $0 } }
    }
}
