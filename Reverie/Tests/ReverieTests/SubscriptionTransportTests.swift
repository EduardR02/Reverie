import GRDB
import XCTest
@testable import Reverie

@MainActor
final class SubscriptionTransportTests: XCTestCase {
    func testUnauthorizedSubscriptionRefreshesExactlyOnceAndNeverUsesPaidKey() async throws {
        let clock = SubscriptionTestClock()
        let old = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let renewed = try Self.jwt(expiration: clock.now.addingTimeInterval(7_200))
        let http = SubscriptionHTTPStub(steps: [try .token(renewed, refresh: "rotated-fixture", expires: 7_200)])
        let (auth, store) = try Self.auth(clock: clock, access: old, http: http)
        let fixture = try Self.fixture(auth: auth, replies: [.unauthorized("server-secret"), .success()])
        defer { fixture.close() }
        let result = try await Self.read(Self.chat(fixture.service, settings: Self.settings()))
        XCTAssertEqual(result.text, "Fixture answer")
        XCTAssertEqual(result.usageEvents, 1)
        let requests = fixture.scenario.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer \(old)", "Bearer \(renewed)"])
        Self.assertSubscriptionOnly(requests)
        XCTAssertEqual(store.saveCount, 1)
        let grants = await http.requests
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants.first?.url?.path, "/oauth/token")
    }

    func testSecondUnauthorizedResponseStopsWithoutThirdRequestOrLeakingServerBody() async throws {
        let clock = SubscriptionTestClock()
        let old = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let renewed = try Self.jwt(expiration: clock.now.addingTimeInterval(7_200))
        let http = SubscriptionHTTPStub(steps: [try .token(renewed, refresh: "rotated-fixture", expires: 7_200)])
        let (auth, _) = try Self.auth(clock: clock, access: old, http: http)
        let secret = "server-secret \(old) \(renewed) unused-paid-key"
        let fixture = try Self.fixture(auth: auth, replies: [.unauthorized(secret), .unauthorized(secret)])
        defer { fixture.close() }
        let error = try await Self.failure(Self.chat(fixture.service, settings: Self.settings()))
        Self.assertRedacted(error, secrets: ["server-secret", old, renewed, "unused-paid-key"])
        XCTAssertFalse(error is CancellationError)
        XCTAssertEqual(fixture.scenario.requests.count, 2)
        Self.assertSubscriptionOnly(fixture.scenario.requests)
        let grants = await http.requests
        XCTAssertEqual(grants.count, 1)
    }

    func testFailedSubscriptionSSEErrorIsRedactedAndObservedCacheUsageStillPersists() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let http = SubscriptionHTTPStub(steps: [])
        let (auth, _) = try Self.auth(clock: clock, access: access, http: http)
        let settings = Self.settings()
        let state = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()), settings: settings)
        let reply = try SubscriptionInferenceScenario.Reply.failed("server-secret \(access) unused-paid-key")
        let fixture = try Self.fixture(auth: auth, replies: [reply], state: state)
        defer { fixture.close() }
        let error = try await Self.failure(Self.chat(fixture.service, settings: settings))
        Self.assertRedacted(error, secrets: ["server-secret", access, "unused-paid-key"])
        XCTAssertEqual(fixture.scenario.requests.count, 1)
        let grants = await http.requests
        XCTAssertTrue(grants.isEmpty, "A failed SSE generation must not replay through token refresh")
        let rows = try state.database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.cachedTokens, 400)
        XCTAssertNil(rows.first?.cost)
        XCTAssertEqual(state.readingStats.tokensCached, 400)
        XCTAssertEqual(try state.database.fetchLifetimeStats().tokensCached, 400)
    }

    func testSubscriptionCacheUsageReachesDashboardAndLedgerWithoutDollarCost() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let (auth, _) = try Self.auth(clock: clock, access: access, http: SubscriptionHTTPStub(steps: []))
        let settings = Self.settings()
        let state = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()), settings: settings)
        let fixture = try Self.fixture(auth: auth, replies: [.success()], state: state)
        defer { fixture.close() }
        let result = try await Self.read(Self.chat(fixture.service, settings: settings))
        XCTAssertEqual(result.usageEvents, 1)
        XCTAssertEqual(state.readingStats.tokensInput, 1_000)
        XCTAssertEqual(state.readingStats.tokensCached, 400)
        XCTAssertEqual(state.readingStats.tokensCacheReportedInput, 1_000)
        XCTAssertEqual(state.readingStats.totalTokens, 1_100)
        XCTAssertEqual(state.processingCostEstimate, 0)
        let lifetime = try state.database.fetchLifetimeStats()
        XCTAssertEqual(lifetime.tokensInput, 1_000)
        XCTAssertEqual(lifetime.tokensCached, 400)
        XCTAssertEqual(lifetime.tokensCacheReportedInput, 1_000)
        let rows = try state.database.fetchLLMCallUsage()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.provider, "OpenAI (ChatGPT)")
        XCTAssertEqual(row.inputTokens, 1_000)
        XCTAssertEqual(row.cachedTokens, 400)
        XCTAssertEqual(row.outputTokens, 80)
        XCTAssertEqual(row.reasoningTokens, 20)
        XCTAssertNil(row.cost)
        Self.assertSubscriptionOnly(fixture.scenario.requests)
    }

    func testQueuedSubscriptionUsesFreshTokenAfterFirstRequestReleasesSlot() async throws {
        let clock = SubscriptionTestClock()
        let old = try Self.jwt(expiration: clock.now.addingTimeInterval(120))
        let renewed = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let http = SubscriptionHTTPStub(steps: [try .token(renewed, refresh: "rotated-fixture", expires: 3_600)])
        let (auth, _) = try Self.auth(clock: clock, access: old, expiresAt: clock.now.addingTimeInterval(120), http: http)
        var settings = Self.settings()
        settings.maxConcurrentRequests = 1
        let state = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()), settings: settings)
        let fixture = try Self.fixture(auth: auth, replies: [.success(held: true), .success()], state: state)
        defer { fixture.close() }
        let first = Task { try await Self.read(Self.chat(fixture.service, settings: settings, message: "First")) }
        try await fixture.scenario.waitForRequests(1)
        let queued = Self.chat(fixture.service, settings: settings, message: "Queued")
        let second = Task { try await Self.read(queued) }
        await Task.yield()
        clock.advance(200)
        fixture.scenario.releaseHeld()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(fixture.scenario.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer \(old)", "Bearer \(renewed)"])
        let grants = await http.requests
        XCTAssertEqual(grants.count, 1)
        Self.assertSubscriptionOnly(fixture.scenario.requests)
    }

    func testLogoutCancelsQueuedSubscriptionBeforeAnySecondInferenceRequest() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let http = SubscriptionHTTPStub(steps: [])
        let (auth, store) = try Self.auth(clock: clock, access: access, http: http)
        var settings = Self.settings()
        settings.maxConcurrentRequests = 1
        let state = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()), settings: settings)
        let fixture = try Self.fixture(auth: auth, replies: [.success(held: true)], state: state)
        defer { fixture.close() }
        let first = Task { try await Self.read(Self.chat(fixture.service, settings: settings, message: "First")) }
        try await fixture.scenario.waitForRequests(1)
        let queued = Self.chat(fixture.service, settings: settings, message: "Queued")
        let second = Task { try await Self.failure(queued) }
        await Task.yield()
        try await auth.signOut()
        fixture.scenario.releaseHeld()
        _ = try await first.value
        let error = try await second.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(fixture.scenario.requests.count, 1)
        XCTAssertNil(store.data)
        let grants = await http.requests
        XCTAssertTrue(grants.isEmpty)
    }

    func testSwitchingToSubscriptionCancelsQueuedPaidRequestWithoutFallback() async throws {
        let clock = SubscriptionTestClock()
        let authHTTP = SubscriptionHTTPStub(steps: [])
        let auth = OpenAISubscriptionAuth(store: SubscriptionTestStore(), transport: { try await authHTTP.send($0) }, now: { clock.now })
        var settings = Self.settings(mode: .apiKey)
        settings.maxConcurrentRequests = 1
        let state = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()), settings: settings)
        let fixture = try Self.fixture(auth: auth, replies: [.success(held: true)], state: state)
        defer { fixture.close() }
        let first = Task { try await Self.read(Self.chat(fixture.service, settings: settings, message: "Already admitted")) }
        try await fixture.scenario.waitForRequests(1)
        let queued = Self.chat(fixture.service, settings: settings, message: "Queued paid request")
        let second = Task { try await Self.failure(queued) }
        await Task.yield()
        state.settings.openAIAuthenticationMode = .chatGPTSubscription
        fixture.scenario.releaseHeld()
        _ = try await first.value
        let error = try await second.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(fixture.scenario.requests.count, 1)
        XCTAssertEqual(fixture.scenario.requests.first?.url?.host, "api.openai.com")
        let grants = await authHTTP.requests
        XCTAssertTrue(grants.isEmpty)
    }

    func testSubscriptionSolImagesOffSparseCompletionCommitsThroughChapterAnalyzer() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let (auth, _) = try Self.auth(clock: clock, access: access, http: SubscriptionHTTPStub(steps: []))
        var settings = Self.settings()
        settings.imagesEnabled = false
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let state = AppState(database: database, settings: settings)
        let fixture = try Self.fixture(auth: auth, replies: [.analysis(sparse: true)], state: state)
        defer { fixture.close() }
        var book = Book(title: "Relativity", author: "Fixture", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Gravity", contentHTML: "<p>Gravity curves spacetime.</p>")
        try database.saveChapter(&chapter)
        let analyzer = ChapterAnalyzer(
            llm: fixture.service, imageService: ImageService(session: fixture.session),
            database: database, settings: settings
        )
        var thinking = ""
        var completed = false
        var annotationEvents = 0
        var quizEvents = 0
        for try await event in analyzer.analyzeChapter(chapter, book: book) {
            switch event {
            case .thinking(let text): thinking = text
            case .annotation: annotationEvents += 1
            case .quiz: quizEvents += 1
            case .complete: completed = true
            case .imageSuggestions: XCTFail("Images-off schema must not produce image suggestions")
            }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(thinking, "Check anchors.\n\nCheck continuity.")
        XCTAssertEqual(annotationEvents, 1)
        XCTAssertEqual(quizEvents, 1)
        XCTAssertEqual(try database.fetchAnnotations(for: chapter).first?.title, "Curvature")
        XCTAssertEqual(try database.fetchQuizzes(for: chapter).count, 1)
        let persisted = try XCTUnwrap(database.fetchChapters(for: book).first)
        XCTAssertTrue(persisted.processed)
        XCTAssertEqual(persisted.summary, "Gravity is described geometrically.")
        let usage = try XCTUnwrap(database.fetchLLMCallUsage().first)
        XCTAssertEqual(usage.task, "insight")
        XCTAssertEqual(usage.cachedTokens, 400)
        XCTAssertNil(usage.cost)
        XCTAssertEqual(fixture.scenario.requests.count, 1)
        Self.assertSubscriptionOnly(fixture.scenario.requests)
        let request = try XCTUnwrap(fixture.scenario.requests.first)
        let body = try providerRequestJSON(request)
        XCTAssertEqual(body["model"] as? String, SupportedModels.OpenAI.gpt61Sol)
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertNil((schema["properties"] as? [String: Any])?["imageSuggestions"])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(["annotations", "quizQuestions", "summary"]))
    }

    func testStructuredSubscriptionUsesAuthoritativeFinalSnapshotRatherThanDraftDeltas() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
        let (auth, _) = try Self.auth(clock: clock, access: access, http: SubscriptionHTTPStub(steps: []))
        var settings = Self.settings()
        settings.imagesEnabled = false
        let fixture = try Self.fixture(auth: auth, replies: [.analysis(sparse: false)])
        defer { fixture.close() }
        var result: LLMService.ChapterAnalysis?
        var usageEvents = 0
        for try await event in fixture.service.analyzeChapterStreaming(
            contentWithBlocks: "[1] Gravity curves spacetime.", rollingSummary: nil,
            bookTitle: nil, author: nil, settings: settings
        ) {
            if case .completed(let analysis) = event { result = analysis }
            if case .usage = event { usageEvents += 1 }
        }
        XCTAssertEqual(result?.annotations.first?.title, "Curvature")
        XCTAssertEqual(result?.summary, "Gravity is described geometrically.")
        XCTAssertEqual(result?.imageSuggestions.count, 0)
        XCTAssertEqual(usageEvents, 1)
    }

    func testSubscriptionAnalysisFailuresNeverCommitButRetainObservedUsageAndDistinctStages() async throws {
        let cases: [(String, SubscriptionInferenceScenario.Reply, String)] = [
            ("EOF", try .analysisFailure(stage: "eof"), "did not complete"),
            ("provider", try .analysisFailure(stage: "provider"), "did not complete"),
            ("parsing", try .analysisFailure(stage: "parsing"), "could not be decoded"),
            ("validation", try .analysisFailure(stage: "validation"), "nonexistent block"),
            ("save", try .analysisFailure(stage: "save"), "forced analysis save failure")
        ]
        for (stage, reply, expectedMessage) in cases {
            let clock = SubscriptionTestClock()
            let access = try Self.jwt(expiration: clock.now.addingTimeInterval(3_600))
            let (auth, _) = try Self.auth(clock: clock, access: access, http: SubscriptionHTTPStub(steps: []))
            var settings = Self.settings()
            settings.imagesEnabled = false
            let queue = try DatabaseQueue()
            let database = try DatabaseService(dbQueue: queue)
            let state = AppState(database: database, settings: settings)
            let fixture = try Self.fixture(auth: auth, replies: [reply], state: state)
            defer { fixture.close() }
            var book = Book(title: "Relativity", author: "Fixture", epubPath: "")
            try database.saveBook(&book)
            var chapter = Chapter(bookId: book.id!, index: 0, title: "Gravity", contentHTML: "<p>Gravity curves spacetime.</p>")
            try database.saveChapter(&chapter)
            if stage == "save" {
                try await queue.write { db in
                    try db.execute(sql: "CREATE TRIGGER fail_analysis BEFORE UPDATE OF processed ON chapters BEGIN SELECT RAISE(ABORT, 'forced analysis save failure'); END")
                }
            }
            let analyzer = ChapterAnalyzer(
                llm: fixture.service, imageService: ImageService(session: fixture.session),
                database: database, settings: settings
            )
            var failure: Error?
            do {
                for try await event in analyzer.analyzeChapter(chapter, book: book) {
                    if case .annotation = event { XCTFail("Invalid analysis emitted a saved annotation: \(stage)") }
                    if case .complete = event { XCTFail("Invalid analysis completed: \(stage)") }
                }
            } catch { failure = error }
            let error = try XCTUnwrap(failure, stage)
            XCTAssertTrue(error.localizedDescription.contains(expectedMessage), "\(stage): \(error)")
            Self.assertRedacted(error, secrets: [access, "unused-paid-key", "server-secret"])
            XCTAssertFalse(error.localizedDescription.contains("Sign in"), stage)
            XCTAssertTrue(try database.fetchAnnotations(for: chapter).isEmpty, stage)
            XCTAssertTrue(try database.fetchQuizzes(for: chapter).isEmpty, stage)
            let persisted = try XCTUnwrap(database.fetchChapters(for: book).first)
            XCTAssertFalse(persisted.processed, stage)
            XCTAssertNil(persisted.summary, stage)
            XCTAssertEqual(try database.fetchLLMCallUsage().count, 1, stage)
            Self.assertSubscriptionOnly(fixture.scenario.requests)
        }
    }

    private static func settings(mode: OpenAIAuthenticationMode = .chatGPTSubscription) -> UserSettings {
        var settings = UserSettings()
        settings.llmProvider = .openai
        settings.llmModel = SupportedModels.OpenAI.gpt61Sol
        settings.openAIAuthenticationMode = mode
        settings.openAIAPIKey = "unused-paid-key"
        return settings
    }

    private static func auth(
        clock: SubscriptionTestClock, access: String, expiresAt: Date? = nil, http: SubscriptionHTTPStub
    ) throws -> (OpenAISubscriptionAuth, SubscriptionTestStore) {
        let tokens = OpenAISubscriptionAuth.StoredTokens(accessToken: access, refreshToken: "refresh-fixture", expiresAt: expiresAt ?? clock.now.addingTimeInterval(3_600))
        let store = SubscriptionTestStore(data: try JSONEncoder().encode(tokens))
        return (OpenAISubscriptionAuth(store: store, transport: { try await http.send($0) }, now: { clock.now }), store)
    }

    private static func jwt(expiration: Date) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "exp": expiration.timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-fixture"]
        ])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture.\(encoded).signature"
    }

    private static func fixture(
        auth: OpenAISubscriptionAuth, replies: [SubscriptionInferenceScenario.Reply], state: AppState? = nil
    ) throws -> SubscriptionServiceFixture {
        let scenario = SubscriptionInferenceScenario(replies: replies)
        SubscriptionInferenceURLProtocol.install(scenario)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionInferenceURLProtocol.self]
        configuration.httpAdditionalHeaders = [SubscriptionInferenceURLProtocol.fixtureHeader: scenario.id]
        let session = URLSession(configuration: configuration)
        let service = LLMService(appState: state, session: session, subscriptionAuth: auth)
        service.recordMode = false
        return SubscriptionServiceFixture(service: service, session: session, scenario: scenario)
    }

    private static func chat(_ service: LLMService, settings: UserSettings, message: String = "Question") -> AsyncThrowingStream<LLMStreamChunk, Error> {
        service.chatStreaming(message: message, contentWithBlocks: "[1] Fixture passage", rollingSummary: nil, settings: settings)
    }

    private static func read(_ stream: AsyncThrowingStream<LLMStreamChunk, Error>) async throws -> (text: String, usageEvents: Int) {
        var text = ""
        var usageEvents = 0
        for try await chunk in stream {
            switch chunk {
            case .content(let delta): text += delta
            case .usage: usageEvents += 1
            case .thinking: break
            }
        }
        return (text, usageEvents)
    }

    private static func failure(_ stream: AsyncThrowingStream<LLMStreamChunk, Error>) async throws -> Error {
        var failure: Error?
        do { _ = try await read(stream) } catch { failure = error }
        return try XCTUnwrap(failure, "Expected subscription request to fail")
    }

    private static func assertSubscriptionOnly(_ requests: [URLRequest], file: StaticString = #filePath, line: UInt = #line) {
        for request in requests {
            XCTAssertEqual(request.url?.host, "chatgpt.com", file: file, line: line)
            XCTAssertEqual(request.url?.path, "/backend-api/codex/responses", file: file, line: line)
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-fixture", file: file, line: line)
            XCTAssertFalse(request.value(forHTTPHeaderField: "Authorization")?.contains("unused-paid-key") ?? true, file: file, line: line)
        }
    }

    private static func assertRedacted(_ error: Error, secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        for secret in secrets {
            XCTAssertFalse(error.localizedDescription.contains(secret), file: file, line: line)
        }
    }
}

@MainActor
private struct SubscriptionServiceFixture {
    let service: LLMService
    let session: URLSession
    let scenario: SubscriptionInferenceScenario

    func close() {
        scenario.releaseHeld()
        session.invalidateAndCancel()
        SubscriptionInferenceURLProtocol.remove(scenario.id)
    }
}

/// Every configured request is intercepted, including unexpected hosts. No fixture can reach inference.
private final class SubscriptionInferenceURLProtocol: URLProtocol {
    static let fixtureHeader = "X-Reverie-Subscription-Fixture"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: SubscriptionInferenceScenario] = [:]

    static func install(_ scenario: SubscriptionInferenceScenario) { lock.withLock { scenarios[scenario.id] = scenario } }
    static func remove(_ id: String) { _ = lock.withLock { scenarios.removeValue(forKey: id) } }
    private static func scenario(_ request: URLRequest) -> SubscriptionInferenceScenario? {
        guard let id = request.value(forHTTPHeaderField: fixtureHeader) else { return nil }
        return lock.withLock { scenarios[id] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario = Self.scenario(request), let reply = scenario.begin(request, receiver: self) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if !reply.held { deliver(reply) }
    }

    func deliver(_ reply: SubscriptionInferenceScenario.Reply) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        // Keep successful terminal fixtures open: the consumer must finish from the
        // provider event, not socket EOF. An immediate didFail would instead race
        // URLSession.bytes(for:) before it has delivered any response bytes.
        if !reply.leavesConnectionOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { Self.scenario(request)?.cancel(self) }
}

private final class SubscriptionInferenceScenario: @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        let held: Bool
        var leavesConnectionOpen = false

        static func unauthorized(_ secret: String) -> Reply {
            Reply(status: 401, body: Data(secret.utf8), held: false)
        }

        static func success(held: Bool = false) throws -> Reply {
            let response: [String: Any] = [
                "status": "completed",
                "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Fixture answer"]]]],
                "usage": usage
            ]
            return try sse([
                ["type": "response.output_text.delta", "delta": "Fixture answer"],
                ["type": "response.completed", "response": response]
            ], held: held)
        }

        static func failed(_ secret: String) throws -> Reply {
            try sse([["type": "response.failed", "response": ["status": "failed", "error": ["message": secret], "usage": usage]]])
        }

        static var analysisText: String {
            #"{"annotations":[{"type":"science","title":"Curvature","content":"Einstein described gravity geometrically.","sourceBlockId":1}],"quizQuestions":[{"question":"What curves?","answer":"Spacetime.","sourceBlockId":1}],"summary":"Gravity is described geometrically."}"#
        }

        static func analysis(sparse: Bool) throws -> Reply {
            let final: [String: Any] = [
                "id": "msg_final", "type": "message", "role": "assistant", "phase": "final_answer",
                "status": "completed", "content": [["type": "output_text", "text": analysisText]]
            ]
            let reasoning: [String: Any] = [
                "id": "rs_1", "type": "reasoning", "encrypted_content": "opaque-fixture",
                "summary": [["type": "summary_text", "text": "Check anchors."], ["type": "summary_text", "text": "Check continuity."]]
            ]
            var events: [[String: Any]] = [
                ["type": "response.output_item.added", "output_index": 0, "item": ["id": "rs_1", "type": "reasoning", "summary": []]],
                ["type": "response.reasoning_summary_text.delta", "item_id": "rs_1", "summary_index": 0, "delta": "Check "],
                ["type": "response.reasoning_summary_text.done", "item_id": "rs_1", "summary_index": 0, "text": "Check anchors."],
                ["type": "response.reasoning_summary_part.done", "item_id": "rs_1", "summary_index": 1, "part": ["type": "summary_text", "text": "Check continuity."]],
                ["type": "response.output_item.done", "output_index": 0, "item": reasoning],
                ["type": "response.output_item.added", "output_index": 1, "item": ["id": "msg_progress", "type": "message", "role": "assistant", "phase": "commentary", "content": []]],
                ["type": "response.output_text.delta", "output_index": 1, "item_id": "msg_progress", "content_index": 0, "delta": "I will check the passage."],
                ["type": "response.output_item.done", "output_index": 1, "item": ["id": "msg_progress", "type": "message", "role": "assistant", "phase": "commentary", "status": "completed", "content": [["type": "output_text", "text": "I will check the passage."]]]],
                ["type": "response.output_item.added", "output_index": 2, "item": ["id": "msg_final", "type": "message", "role": "assistant", "phase": "final_answer", "content": []]],
                // Sparse final message deltas are not a prefix of its authoritative snapshot.
                ["type": "response.output_text.delta", "output_index": 2, "item_id": "msg_final", "content_index": 0, "delta": "geometrically.\"}"],
                ["type": "response.output_item.done", "output_index": 2, "item": final]
            ]
            let response: [String: Any] = sparse
                ? ["id": "resp_fixture", "usage": usage]
                : ["id": "resp_fixture", "status": "completed", "output": [reasoning, final], "usage": usage]
            events.append(["type": "response.completed", "response": response])
            // Completion, not subsequent framing/connection activity, decides success.
            let reply = try sse(events)
            return Reply(
                status: 200, body: reply.body + Data("data: malformed-after-completion\n\n".utf8),
                held: false, leavesConnectionOpen: true
            )
        }

        static func analysisFailure(stage: String) throws -> Reply {
            let text: String
            switch stage {
            case "parsing": text = "This is not JSON."
            case "validation": text = analysisText.replacingOccurrences(of: #""sourceBlockId":1"#, with: #""sourceBlockId":99"#)
            default: text = analysisText
            }
            let output: [[String: Any]] = [["id": "msg_final", "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "content": [["type": "output_text", "text": text]]]]
            var events: [[String: Any]] = [
                ["type": "response.created", "response": ["id": "resp_failure", "usage": usage]],
                ["type": "response.output_text.delta", "delta": text]
            ]
            if stage == "provider" {
                events.append(["type": "response.failed", "response": ["status": "failed", "error": ["message": "server-secret"], "usage": usage]])
            } else if stage != "eof" {
                events.append(["type": "response.completed", "response": ["status": "completed", "output": output, "usage": usage]])
            }
            return try sse(events)
        }

        private static var usage: [String: Any] {
            ["input_tokens": 1_000, "output_tokens": 100,
             "input_tokens_details": ["cached_tokens": 400], "output_tokens_details": ["reasoning_tokens": 20]]
        }

        private static func sse(_ events: [[String: Any]], held: Bool = false) throws -> Reply {
            let payload = try events.map { "data: \(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self))\n\n" }.joined()
            return Reply(status: 200, body: Data(payload.utf8), held: held)
        }
    }

    let id = UUID().uuidString
    private let lock = NSLock()
    private var replies: [Reply]
    private var seen: [URLRequest] = []
    private var held: [(SubscriptionInferenceURLProtocol, Reply)] = []
    private var waiters: [(Int, XCTestExpectation)] = []
    var requests: [URLRequest] { lock.withLock { seen } }

    init(replies: [Reply]) { self.replies = replies }

    func begin(_ request: URLRequest, receiver client: SubscriptionInferenceURLProtocol) -> Reply? {
        let result = lock.withLock { () -> (Reply?, [XCTestExpectation]) in
            seen.append(request)
            let ready = waiters.filter { seen.count >= $0.0 }.map(\.1)
            waiters.removeAll { seen.count >= $0.0 }
            guard !replies.isEmpty else { return (nil, ready) }
            let reply = replies.removeFirst()
            if reply.held { held.append((client, reply)) }
            return (reply, ready)
        }
        for waiter in result.1 { waiter.fulfill() }
        return result.0
    }

    func waitForRequests(_ count: Int) async throws {
        let expectation = XCTestExpectation(description: "Intercepting \(count) subscription fixture requests")
        let ready = lock.withLock {
            if seen.count >= count { return true }
            waiters.append((count, expectation))
            return false
        }
        if ready { return }
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        lock.withLock { waiters.removeAll { $0.1 === expectation } }
        XCTAssertEqual(result, .completed)
        if result != .completed { throw URLError(.timedOut) }
    }

    func releaseHeld() {
        let pending = lock.withLock {
            let pending = held
            held.removeAll()
            return pending
        }
        for (client, reply) in pending { client.deliver(reply) }
    }

    func cancel(_ client: SubscriptionInferenceURLProtocol) {
        lock.withLock { held.removeAll { $0.0 === client } }
    }
}
