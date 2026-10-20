import GRDB
import XCTest
@testable import Reverie

@MainActor
final class CachedInputAccountingTests: XCTestCase {
    func testFreshAndCachedInputAreDisjointAndCountTowardTotalOnce() {
        for cached in [0, 950, 1_000] {
            var stats = ReadingStats()
            stats.addTokens(input: 1_000, reasoning: 10, output: 20, cached: cached, cacheWrite: cached == 950 ? 40 : 0)

            XCTAssertEqual(stats.uncachedInputTokens, 1_000 - cached)
            XCTAssertEqual(stats.tokensCached, cached)
            XCTAssertEqual(stats.uncachedInputTokens + cached + stats.tokensReasoning + stats.tokensOutput, 1_030)
            XCTAssertEqual(stats.totalTokens, 1_030)
        }
    }

    func testCacheReadsAndWritesAreSubsetsAndUnknownInputIsExcludedFromHitRate() throws {
        var stats = ReadingStats()
        XCTAssertNil(stats.tokensCached)
        XCTAssertNil(stats.tokensCacheWrite)
        XCTAssertNil(stats.cacheHitRate)

        stats.addTokens(input: 1_000, reasoning: 10, output: 20, cached: nil)
        XCTAssertNil(stats.tokensCached)
        stats.addTokens(input: 100, reasoning: 10, output: 20, cached: 0, cacheWrite: 0)
        XCTAssertEqual(stats.tokensCached, 0)
        XCTAssertEqual(stats.tokensCacheWrite, 0)
        XCTAssertEqual(try XCTUnwrap(stats.cacheHitRate), 0)
        stats.addTokens(input: 300, reasoning: 10, output: 20, cached: 120, cacheWrite: 40)

        XCTAssertEqual(stats.tokensInput, 1_400)
        XCTAssertEqual(stats.tokensCached, 120)
        XCTAssertEqual(stats.tokensCacheWrite, 40)
        XCTAssertEqual(stats.tokensCacheReportedInput, 400)
        XCTAssertEqual(try XCTUnwrap(stats.cacheHitRate), 0.3, accuracy: 0.000001)
        XCTAssertEqual(stats.totalTokens, 1_490, "Cache reads and writes must not inflate total tokens")
    }

    func testZeroInputDoesNotInventAHitRateAndFullCacheHitsReachOne() throws {
        var stats = ReadingStats()
        stats.addTokens(input: 0, reasoning: 0, output: 0, cached: 0, cacheWrite: 0)
        XCTAssertEqual(stats.tokensCached, 0)
        XCTAssertNil(stats.cacheHitRate)
        stats.addTokens(input: 200, reasoning: 0, output: 0, cached: 200)
        XCTAssertEqual(try XCTUnwrap(stats.cacheHitRate), 1)
        XCTAssertEqual(stats.totalTokens, 200)
    }

    func testMigrationBackfillsKnownReadsWithoutReplayingLifetimeUsageOnReopen() throws {
        let queue = try DatabaseQueue()
        try DatabaseService.makeMigrator().migrate(queue, upTo: "v5_llm_call_usage")
        try queue.write { db in
            try db.execute(sql: "UPDATE lifetime_stats SET tokensInput = 9000, tokensReasoning = 200, tokensOutput = 600, totalWords = 1234 WHERE id = 1")
            for (provider, input, cached) in [("google", 1_000, nil as Int?), ("openai", 200, 0), ("anthropic", 500, 300)] {
                try db.execute(
                    sql: """
                    INSERT INTO llm_call_usage (createdAt, dateKey, provider, model, task, inputTokens, outputTokens, cachedTokens)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [Date(), ReadingStats.dateKey(for: Date()), provider, "historical-model", "chat", input, 80, cached]
                )
            }
        }

        let database = try DatabaseService(dbQueue: queue)
        let migrated = try database.fetchLifetimeStats()
        XCTAssertEqual(migrated.tokensInput, 9_000)
        XCTAssertEqual(migrated.tokensReasoning, 200)
        XCTAssertEqual(migrated.tokensOutput, 600)
        XCTAssertEqual(migrated.totalWords, 1_234)
        XCTAssertEqual(migrated.tokensCached, 300)
        XCTAssertEqual(migrated.tokensCacheReportedInput, 700)
        XCTAssertNil(migrated.tokensCacheWrite, "Historical writes were not stored and cannot be inferred")
        XCTAssertEqual(try XCTUnwrap(migrated.cacheHitRate), 300.0 / 700.0, accuracy: 0.000001)
        XCTAssertTrue(try database.fetchLLMCallUsage().allSatisfy { $0.cacheWriteTokens == nil })

        let state = AppState(database: database, settings: UserSettings())
        state.addTokens(input: 100, reasoning: 5, output: 20, cached: 50, cacheWrite: 10)
        state.addReadingTime(seconds: 5) // An unrelated stats save must retain cache accounting.
        for _ in 0..<3 {
            let reopened = try DatabaseService(dbQueue: queue)
            let stats = try reopened.fetchLifetimeStats()
            XCTAssertEqual(stats.tokensInput, 9_100)
            XCTAssertEqual(stats.totalTokens, 9_925)
            XCTAssertEqual(stats.tokensCached, 350)
            XCTAssertEqual(stats.tokensCacheWrite, 10)
            XCTAssertEqual(stats.tokensCacheReportedInput, 800)
        }
    }

    func testMigrationPreservesUnreportedVersusReportedZero() throws {
        for reportedZero in [false, true] {
            let queue = try DatabaseQueue()
            try DatabaseService.makeMigrator().migrate(queue, upTo: "v5_llm_call_usage")
            try queue.write { db in
                try db.execute(sql: "UPDATE lifetime_stats SET tokensInput = 1000 WHERE id = 1")
                try db.execute(
                    sql: """
                    INSERT INTO llm_call_usage (createdAt, dateKey, provider, model, task, inputTokens, outputTokens, cachedTokens)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [Date(), ReadingStats.dateKey(for: Date()), "google", "historical-model", "chat", 1_000, 0, reportedZero ? 0 : nil]
                )
            }
            let stats = try DatabaseService(dbQueue: queue).fetchLifetimeStats()
            XCTAssertEqual(stats.tokensCached, reportedZero ? 0 : nil)
            XCTAssertEqual(stats.tokensCacheReportedInput, reportedZero ? 1_000 : 0)
            if reportedZero {
                XCTAssertEqual(try XCTUnwrap(stats.cacheHitRate), 0)
            } else {
                XCTAssertNil(stats.cacheHitRate)
            }
        }
    }

    func testCacheStatsAndLedgerOptionalsSurviveDiskReopenWithoutDoubleCounting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.sqlite").path
        do {
            let database = try DatabaseService(dbQueue: DatabaseQueue(path: path))
            let state = AppState(database: database, settings: UserSettings())
            for (input, cached, write) in [(1_000, nil as Int?, nil as Int?), (200, 0, 0), (500, 300, 100)] {
                state.addTokens(input: input, reasoning: 10, output: 20, cached: cached, cacheWrite: write)
                var usage = LLMCallUsage(provider: "fixture", model: "fixture", task: "chat", inputTokens: input, outputTokens: 20, reasoningTokens: 10, cachedTokens: cached, cacheWriteTokens: write)
                try database.saveLLMCallUsage(&usage)
            }
        }
        for _ in 0..<3 {
            let database = try DatabaseService(dbQueue: DatabaseQueue(path: path))
            let state = AppState(database: database, settings: UserSettings())
            state.refreshReadingStats()
            XCTAssertEqual(state.readingStats.tokensInput, 1_700)
            XCTAssertEqual(state.readingStats.totalTokens, 1_790)
            XCTAssertEqual(state.readingStats.tokensCached, 300)
            XCTAssertEqual(state.readingStats.tokensCacheWrite, 100)
            XCTAssertEqual(state.readingStats.tokensCacheReportedInput, 700)
            let rows = try database.fetchLLMCallUsage()
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows.map(\.cachedTokens), [nil, 0, 300])
            XCTAssertEqual(rows.map(\.cacheWriteTokens), [nil, 0, 100])
        }
    }

    func testProviderReportedCacheUsageUpdatesDashboardAndPersistsFromHTTP() async throws {
        let state = try await providerFixture()
        XCTAssertEqual(state.readingStats.tokensInput, 3_900)
        XCTAssertEqual(state.readingStats.tokensCached, 950)
        XCTAssertEqual(state.readingStats.tokensCacheWrite, 400)
        XCTAssertEqual(state.readingStats.tokensCacheReportedInput, 3_900)
        XCTAssertEqual(state.readingStats.totalTokens, 4_180)
        let persisted = try state.database.fetchLifetimeStats()
        XCTAssertEqual(persisted.tokensCached, state.readingStats.tokensCached)
        XCTAssertEqual(persisted.tokensCacheWrite, state.readingStats.tokensCacheWrite)
        XCTAssertEqual(persisted.cacheHitRate, state.readingStats.cacheHitRate)
    }

    func testHTTPReportingDistinguishesUnknownCacheFromExplicitZeroAfterReload() async throws {
        for reportedZero in [false, true] {
            let database = try DatabaseService(dbQueue: DatabaseQueue())
            let state = AppState(database: database, settings: UserSettings())
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CachedAccountingURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Reverie-Cache-Fixture": reportedZero ? "zero" : "unknown"]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let service = LLMService(appState: state, session: session)
            service.recordMode = false
            var settings = UserSettings()
            settings.llmProvider = .google
            settings.llmModel = SupportedModels.Google.gemini3FlashPreview
            settings.googleAPIKey = "mock-key"
            for try await _ in service.chatStreaming(message: "Question?", contentWithBlocks: "[1] Text", rollingSummary: nil, settings: settings) {}

            let row = try XCTUnwrap(database.fetchLLMCallUsage().first)
            let restored = try database.fetchLifetimeStats()
            XCTAssertEqual(row.cachedTokens, reportedZero ? 0 : nil)
            XCTAssertEqual(state.readingStats.tokensCached, reportedZero ? 0 : nil)
            XCTAssertEqual(restored.tokensCached, reportedZero ? 0 : nil)
            XCTAssertEqual(restored.tokensCacheReportedInput, reportedZero ? 1_000 : 0)
            XCTAssertNil(restored.tokensCacheWrite)
            if reportedZero {
                XCTAssertEqual(try XCTUnwrap(restored.cacheHitRate), 0)
            } else {
                XCTAssertNil(restored.cacheHitRate)
            }
        }
    }

    private func providerFixture() async throws -> AppState {
        let database = try DatabaseService(dbQueue: DatabaseQueue())
        let state = AppState(database: database, settings: UserSettings())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachedAccountingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = LLMService(appState: state, session: session)
        service.recordMode = false
        let fixtures: [(LLMProvider, String, Int, Int, Int?)] = [
            (.google, SupportedModels.Google.gemini3FlashPreview, 1_000, 300, nil),
            (.anthropic, SupportedModels.Anthropic.sonnet45, 1_900, 400, 300),
            (.openai, SupportedModels.OpenAI.gpt54, 1_000, 250, 100)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let (provider, model, input, cached, write) = fixture
            var settings = UserSettings()
            settings.llmProvider = provider
            settings.llmModel = model
            settings.googleAPIKey = "mock-key"
            settings.anthropicAPIKey = "mock-key"
            settings.openAIAPIKey = "mock-key"
            let before = state.readingStats
            for try await _ in service.chatStreaming(message: "Question?", contentWithBlocks: "[1] Text", rollingSummary: nil, settings: settings) {}
            XCTAssertEqual(state.readingStats.tokensInput - before.tokensInput, input)
            XCTAssertEqual((state.readingStats.tokensCached ?? 0) - (before.tokensCached ?? 0), cached)
            let rows = try database.fetchLLMCallUsage()
            let row = try XCTUnwrap(rows.last)
            XCTAssertEqual(row.provider, provider.rawValue)
            XCTAssertEqual(row.inputTokens, input)
            XCTAssertEqual(row.cachedTokens, cached)
            XCTAssertEqual(row.cacheWriteTokens, write)
            XCTAssertEqual(rows.count, index + 1)
        }
        return state
    }
}

/// Stateless mock transport: all requests are intercepted, so these fixtures cannot spend API credits.
private final class CachedAccountingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch url.host {
        case "generativelanguage.googleapis.com":
            let cacheField: String
            switch request.value(forHTTPHeaderField: "X-Reverie-Cache-Fixture") {
            case "unknown": cacheField = ""
            case "zero": cacheField = ",\"cachedContentTokenCount\":0"
            default: cacheField = ",\"cachedContentTokenCount\":300"
            }
            body = """
            {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Answer"}]}}],"usageMetadata":{"promptTokenCount":1000,"candidatesTokenCount":80,"thoughtsTokenCount":20\(cacheField)}}
            """
        case "api.anthropic.com":
            body = """
            {"id":"msg_fixture","type":"message","role":"assistant","content":[{"type":"text","text":"Answer"}],"stop_reason":"end_turn","usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400,"output_tokens":80}}
            """
        case "api.openai.com":
            body = """
            {"id":"resp_fixture","object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}],"usage":{"input_tokens":1000,"input_tokens_details":{"cached_tokens":250,"cache_write_tokens":100},"output_tokens":100,"output_tokens_details":{"reasoning_tokens":20}}}
            """
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
