import XCTest
@testable import Reverie

@MainActor
final class AsyncConcurrencyTests: XCTestCase {
    var mockSession: URLSession!
    var llmService: LLMService!
    var imageService: ImageService!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        llmService = LLMService(session: mockSession)
        llmService.recordMode = false
        imageService = ImageService(session: mockSession)
    }

    override func tearDown() async throws {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    // MARK: - Concurrent Operations Tests

    func testMixedLLMAndImageRequests() async throws {
        let expectation = XCTestExpectation(description: "Mixed requests should complete")
        expectation.expectedFulfillmentCount = 2

        var settings = UserSettings()
        settings.googleAPIKey = "test-key"

        MockURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains("generateContent") {
                Thread.sleep(forTimeInterval: 0.05)
                let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                return (HTTPURLResponse(url: URL(string: "https://google.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, """
                {
                    "candidates": [{
                        "content": {
                            "parts": [{
                                "inlineData": {
                                    "mimeType": "image/png",
                                    "data": "\(pngBase64)"
                                }
                            }]
                        }
                    }]
                }
                """.data(using: .utf8)!)
            } else {
                Thread.sleep(forTimeInterval: 0.05)
                return (HTTPURLResponse(url: URL(string: "https://google.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, """
                {
                    "candidates": [{
                        "content": {
                            "parts": [{
                                "text": "{\\"summary\\": \\"Summary\\", \\"annotations\\": [], \\"quizQuestions\\": [], \\"imageSuggestions\\": []}"
                            }]
                        }
                    }],
                    "usageMetadata": { "promptTokenCount": 100, "candidatesTokenCount": 50 }
                }
                """.data(using: .utf8)!)
            }
        }

        let llmTask = Task {
            do {
                _ = try await llmService.analyzeChapter(
                    contentWithBlocks: "Test content",
                    rollingSummary: nil,
                    bookTitle: nil,
                    author: nil,
                    settings: settings
                )
            } catch {
                XCTFail("LLM request should not fail: \(error)")
            }
            expectation.fulfill()
        }

        let imageTask = Task {
            do {
                _ = try await imageService.generateImage(
                    prompt: "Test prompt",
                    model: .gemini25Flash,
                    apiKey: "test-key"
                )
            } catch {
                XCTFail("Image request should not fail: \(error)")
            }
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        llmTask.cancel()
        imageTask.cancel()
        _ = await llmTask.result
        _ = await imageTask.result
    }

    func testNoDataCorruptionWithParallelWrites() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let writeCount = 10
        let expectation = XCTestExpectation(description: "All writes should complete without corruption")
        expectation.expectedFulfillmentCount = writeCount

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for i in 0..<writeCount {
                group.addTask {
                    let data = "Content \(i)".data(using: .utf8)!
                    let path = tempDir.appendingPathComponent("file_\(i).txt")
                    try data.write(to: path)
                    return (i, data)
                }
            }

            for try await (index, originalData) in group {
                let path = tempDir.appendingPathComponent("file_\(index).txt")
                let readData = try? Data(contentsOf: path)
                XCTAssertEqual(readData, originalData, "Data should not be corrupted for file \(index)")
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    // MARK: - Error Propagation Tests

    func testErrorsInAsyncContextPropagateCorrectly() async throws {
        MockURLProtocol.stubError = NSError(domain: "Test", code: -1001, userInfo: nil)

        var settings = UserSettings()
        settings.googleAPIKey = "test-key"

        var caughtError: Error?
        do {
            _ = try await llmService.analyzeChapter(
                contentWithBlocks: "Test content",
                rollingSummary: nil,
                bookTitle: nil,
                author: nil,
                settings: settings
            )
        } catch {
            caughtError = error
        }

        XCTAssertNotNil(caughtError)
    }

    func testOneFailureDoesntCrashSystem() async throws {
        let expectation = XCTestExpectation(description: "Other tasks should complete despite one failure")
        expectation.expectedFulfillmentCount = 2

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                throw NSError(domain: "Test", code: 500, userInfo: nil)
            }
            return (HTTPURLResponse(url: URL(string: "https://google.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, """
            {
                "candidates": [{
                    "content": {
                        "parts": [{
                            "text": "{\\"summary\\": \\"Summary\\", \\"annotations\\": [], \\"quizQuestions\\": [], \\"imageSuggestions\\": []}"
                        }]
                    }
                }],
                "usageMetadata": { "promptTokenCount": 100, "candidatesTokenCount": 50 }
            }
            """.data(using: .utf8)!)
        }

        var settings = UserSettings()
        settings.googleAPIKey = "test-key"

        let task1 = Task {
            do {
                _ = try await llmService.analyzeChapter(
                    contentWithBlocks: "Content 1",
                    rollingSummary: nil,
                    bookTitle: nil,
                    author: nil,
                    settings: settings
                )
                XCTFail("First request should fail")
            } catch {
            }
            expectation.fulfill()
        }

        let task2 = Task {
            do {
                _ = try await llmService.analyzeChapter(
                    contentWithBlocks: "Content 2",
                    rollingSummary: nil,
                    bookTitle: nil,
                    author: nil,
                    settings: settings
                )
            } catch {
                XCTFail("Second request should succeed")
            }
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        task1.cancel()
        task2.cancel()
        _ = await task1.result
        _ = await task2.result
    }

    func testStreamingErrorPropagates() async throws {
        MockURLProtocol.requestHandler = { request in
            throw NSError(domain: "Stream", code: 400, userInfo: nil)
        }

        var settings = UserSettings()
        settings.googleAPIKey = "test-key"

        let stream = llmService.analyzeChapterStreaming(
            contentWithBlocks: "Test content",
            rollingSummary: nil,
            bookTitle: nil,
            author: nil,
            settings: settings
        )

        var receivedError: Error?
        let expectation = XCTestExpectation(description: "Stream should error")

        let task = Task {
            do {
                for try await _ in stream {
                }
            } catch {
                receivedError = error
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedError)
        task.cancel()
        _ = await task.result
    }

    func testConcurrentImageGenerationNoRaceConditions() async throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: URL(string: "https://google.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, """
            {
                "candidates": [{
                    "content": {
                        "parts": [{
                            "inlineData": {
                                "mimeType": "image/png",
                                "data": "\(pngBase64)"
                            }
                        }]
                    }
                }]
            }
            """.data(using: .utf8)!)
        }

        let suggestions = (0..<5).map { i in
            ImageService.ImageSuggestionInput(
                excerpt: "Excerpt \(i)",
                prompt: "Prompt \(i)",
                sourceBlockId: i
            )
        }

        let results = await imageService.generateImages(
            from: suggestions,
            model: .gemini25Flash,
            apiKey: "test-key",
            maxConcurrent: 5
        )

        XCTAssertEqual(results.count, 5)
        let ids = Set(results.map { $0.sourceBlockId })
        XCTAssertEqual(ids.count, 5)
    }

    func testTaskPriorityPropagation() async throws {
        let results: [Int] = await withTaskGroup(of: Int.self) { group in
            group.addTask(priority: .low) { 1 }
            group.addTask(priority: .high) { 2 }
            group.addTask(priority: .medium) { 3 }
            group.addTask(priority: .userInitiated) { 4 }

            var results: [Int] = []
            for await value in group {
                results.append(value)
            }
            return results
        }

        XCTAssertEqual(results.count, 4)
    }

    func testAsyncSequenceCancellationDuringIteration() async throws {
        let stream = AsyncThrowingStream<Int, Error> { continuation in
            for i in 0..<10 {
                continuation.yield(i)
            }
            continuation.finish()
        }

        var collected: [Int] = []

        let task = Task {
            for try await value in stream {
                collected.append(value)
                if Task.isCancelled {
                    break
                }
            }
        }

        task.cancel()
        try? await task.value
        XCTAssertLessThanOrEqual(collected.count, 6)
    }

    func testThrowingTaskGroupPropagatesErrors() async throws {
        let testError = NSError(domain: "Test", code: 42, userInfo: nil)
        var caughtError: Error?

        let didThrow = await Task {
            var threw = false
            do {
                _ = try await withThrowingTaskGroup(of: Int.self) { group in
                    group.addTask {
                        throw testError
                    }
                    group.addTask { 0 }
                    // When one task throws, group cancels and returns nil
                    // The throwing task's error is propagated when we iterate
                    for try await value in group {
                        _ = value
                    }
                    return 0
                }
            } catch {
                caughtError = error
                threw = true
            }
            return threw
        }.value

        XCTAssertTrue(didThrow)
        XCTAssertNotNil(caughtError)
        XCTAssertEqual((caughtError! as NSError).code, 42)
    }

    func testPartialFailureInTaskGroup() async throws {
        let testError = NSError(domain: "Test", code: 42, userInfo: nil)
        var caughtError: Error?
        
        let didThrow = await Task {
            var threw = false
            do {
                _ = try await withThrowingTaskGroup(of: Int?.self) { group in
                    group.addTask { 1 }
                    group.addTask {
                        throw testError
                    }
                    group.addTask { 3 }

                    var allResults: [Int?] = []
                    for try await result in group {
                        allResults.append(result)
                    }
                    return allResults
                }
            } catch {
                caughtError = error
                threw = true
            }
            return threw
        }.value
        
        XCTAssertTrue(didThrow)
        XCTAssertNotNil(caughtError)
        XCTAssertEqual((caughtError! as NSError).code, 42)
    }
}
