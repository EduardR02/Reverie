import XCTest
@testable import Reverie

@MainActor
final class ImageServiceTests: XCTestCase {
    var imageService: ImageService!
    var mockSession: URLSession!
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        imageService = ImageService(session: mockSession)

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        LibraryPaths.configureTestRoot(tempDir)
    }

    override func tearDown() async throws {
        LibraryPaths.configureTestRoot(nil)
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.requestHandler = nil

        if tempDir != nil {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await super.tearDown()
    }

    // MARK: - Sanitized Image Data Tests

    func testSanitizedImageDataWithDataURLPrefix() throws {
        let testBase64 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let result = imageService.testSanitizeBase64Image(testBase64, mimeType: "image/png")
        XCTAssertFalse(result.isEmpty)
    }

    func testSanitizedImageDataWithWhitespace() throws {
        let rawBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let base64WithWhitespace = """
        \(rawBase64.prefix(10))

        \(rawBase64.suffix(10))
        """
        let result = imageService.testSanitizeBase64Image(base64WithWhitespace, mimeType: "image/png")
        XCTAssertFalse(result.isEmpty)
    }

    func testSanitizedImageDataPNG() throws {
        let validPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let result = imageService.testSanitizeBase64Image(validPNG, mimeType: "image/png")
        XCTAssertFalse(result.isEmpty)
        let data = Data(base64Encoded: result)
        XCTAssertNotNil(data)
        XCTAssertTrue(data!.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testSanitizedImageDataJPEG() throws {
        let validJPEG = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAB//2Q=="
        let result = imageService.testSanitizeBase64Image(validJPEG, mimeType: "image/jpeg")
        XCTAssertFalse(result.isEmpty)
        let data = Data(base64Encoded: result)
        XCTAssertNotNil(data)
    }

    func testSanitizedImageDataInvalidBase64() throws {
        let invalidBase64 = "not-valid-base64!!!"
        let result = imageService.testSanitizeBase64Image(invalidBase64, mimeType: "image/png")
        XCTAssertFalse(result.isEmpty)
    }

    func testSanitizedImageDataEmptyMimeType() throws {
        let validBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let result = imageService.testSanitizeBase64Image(validBase64, mimeType: "")
        XCTAssertFalse(result.isEmpty)
    }

    func testSanitizedImageDataWithTrailer() throws {
        let base64WithTrailer = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==AElFTkSuQmCC"
        let result = imageService.testSanitizeBase64Image(base64WithTrailer, mimeType: "image/png")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Find PNG End Tests

    func testFindPngEndWithValidPNG() throws {
        let pngWithIEND = createPNGWithIEND()
        let result = imageService.testFindPngEnd(pngWithIEND)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!, 0)
    }

    func testFindPngEndWithoutIEND() throws {
        let pngWithoutIEND = createPNGWithoutIEND()
        let result = imageService.testFindPngEnd(pngWithoutIEND)
        XCTAssertNil(result)
    }

    func testFindPngEndEmptyData() throws {
        let emptyData = Data()
        let result = imageService.testFindPngEnd(emptyData)
        XCTAssertNil(result)
    }

    func testFindPngEndTruncatedData() throws {
        let truncatedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let result = imageService.testFindPngEnd(truncatedPNG)
        XCTAssertNil(result)
    }

    func testFindPngEndInvalidSignature() throws {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(repeating: 0, count: 100))
        let result = imageService.testFindPngEnd(data)
        XCTAssertNil(result)
    }

    func testFindPngEndPartialChunk() throws {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(contentsOf: [0x08, 0x02])
        data.append(contentsOf: [0x00, 0x00, 0x00])
        data.append(contentsOf: [0x90, 0x77, 0x53, 0xDE])
        let result = imageService.testFindPngEnd(data)
        XCTAssertNil(result)
    }

    // MARK: - Save Image Tests

    func testSaveImageCreatesDirectory() throws {
        let pngData = createMinimalPNG()
        let bookId: Int64 = 12345
        let chapterId: Int64 = 67890

        let path = try imageService.saveImage(pngData, for: bookId, chapterId: chapterId)

        let directoryURL = LibraryPaths.imagesDirectory.appendingPathComponent("\(bookId)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSaveImageValidPNG() throws {
        let pngData = createMinimalPNG()
        let path = try imageService.saveImage(pngData, for: 1, chapterId: 1)

        let savedData = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(savedData, pngData)
    }

    func testSaveImageInvalidData() throws {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])
        let path = try imageService.saveImage(invalidData, for: 2, chapterId: 2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSaveImageMultipleImagesSameChapter() throws {
        let pngData = createMinimalPNG()
        let paths = try (0..<3).map { i in
            try imageService.saveImage(pngData, for: 3, chapterId: 3)
        }

        XCTAssertEqual(paths.count, 3)
        let uniquePaths = Set(paths)
        XCTAssertEqual(uniquePaths.count, 3)
    }

    func testSaveImageGeneratesUniqueFilenames() throws {
        let pngData = createMinimalPNG()
        let path1 = try imageService.saveImage(pngData, for: 4, chapterId: 4)
        let path2 = try imageService.saveImage(pngData, for: 4, chapterId: 4)

        XCTAssertNotEqual(path1, path2)
    }

    // MARK: - Generate Image Tests

    func testGenerateImageSuccess() async throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let response = """
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
        """
        MockURLProtocol.stubResponseData = response.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let result = try await imageService.generateImage(
            prompt: "Test prompt",
            model: ImageModel.gemini25Flash,
            apiKey: "test-key"
        )

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testGenerateImageMissingAPIKey() async throws {
        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: ""
            )
            XCTFail("Should throw missing API key error")
        } catch {
            XCTAssertTrue(error is ImageService.ImageError)
            if case .missingAPIKey = error as? ImageService.ImageError {
                // Expected
            } else {
                XCTFail("Expected missingAPIKey error")
            }
        }
    }

    func testGenerateImageMissingAPIKeyWithWhitespace() async throws {
        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: "   "
            )
            XCTFail("Should throw missing API key error")
        } catch {
            XCTAssertTrue(error is ImageService.ImageError)
            if case .missingAPIKey = error as? ImageService.ImageError {
                // Expected
            } else {
                XCTFail("Expected missingAPIKey error")
            }
        }
    }

    func testGenerateImageAPIError() async throws {
        let errorResponse = """
        {
            "error": {
                "message": "Rate limit exceeded",
                "code": 429
            }
        }
        """
        MockURLProtocol.stubResponseData = errorResponse.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )

        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: "test-key"
            )
            XCTFail("Should throw API error")
        } catch {
            XCTAssertTrue(error is ImageService.ImageError)
            if case .apiError(let message) = error as? ImageService.ImageError {
                XCTAssertTrue(message.contains("Rate limit exceeded"))
            } else {
                XCTFail("Expected apiError, got \(error)")
            }
        }
    }

    func testGenerateImageHTTPError() async throws {
        MockURLProtocol.stubResponseData = "Internal Server Error".data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )

        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: "test-key"
            )
            XCTFail("Should throw HTTP error")
        } catch {
            XCTAssertTrue(error is ImageService.ImageError)
            if case .httpError(let code) = error as? ImageService.ImageError {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        }
    }

    func testGenerateImageInvalidResponseMissingCandidates() async throws {
        let response = """
        {
            "content": {}
        }
        """
        MockURLProtocol.stubResponseData = response.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: "test-key"
            )
            XCTFail("Should throw invalid response error")
        } catch {
            XCTAssertTrue(error is ImageService.ImageError)
            if case .invalidResponse = error as? ImageService.ImageError {
                // Expected
            } else {
                XCTFail("Expected invalidResponse error")
            }
        }
    }

    func testGenerateImageInvalidResponseEmptyInlineData() async throws {
        let response = """
        {
            "candidates": [{
                "content": {
                    "parts": [{}]
                }
            }]
        }
        """
        MockURLProtocol.stubResponseData = response.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: "test-key"
            )
            XCTFail("Should throw invalid response error")
        } catch {
            XCTAssertTrue(error is ImageService.ImageError)
            if case .invalidResponse = error as? ImageService.ImageError {
                // Expected
            } else {
                XCTFail("Expected invalidResponse error")
            }
        }
    }

    func testGenerateImageNetworkError() async throws {
        MockURLProtocol.stubError = NSError(domain: "Test", code: -1009, userInfo: nil)

        do {
            _ = try await imageService.generateImage(
                prompt: "Test prompt",
                model: ImageModel.gemini25Flash,
                apiKey: "test-key"
            )
            XCTFail("Should throw network error")
        } catch {
            XCTAssertFalse(error is ImageService.ImageError)
        }
    }

    // MARK: - Generate Images Tests

    func testGenerateImagesSuccess() async throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let response = """
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
        """
        MockURLProtocol.stubResponseData = response.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let suggestions = [
            ImageService.ImageSuggestionInput(excerpt: "Excerpt 1", prompt: "Prompt 1", sourceBlockId: 1),
            ImageService.ImageSuggestionInput(excerpt: "Excerpt 2", prompt: "Prompt 2", sourceBlockId: 2),
            ImageService.ImageSuggestionInput(excerpt: "Excerpt 3", prompt: "Prompt 3", sourceBlockId: 3)
        ]

        let results = await imageService.generateImages(
            from: suggestions,
            model: ImageModel.gemini25Flash,
            apiKey: "test-key",
            maxConcurrent: 3
        )


        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].sourceBlockId, 1)
        XCTAssertEqual(results[1].sourceBlockId, 2)
        XCTAssertEqual(results[2].sourceBlockId, 3)
    }

    func testGenerateImagesEmptyInput() async throws {
        let results = await imageService.generateImages(
            from: [],
            model: ImageModel.gemini25Flash,
            apiKey: "test-key"
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testGenerateImagesMissingAPIKey() async throws {
        let results = await imageService.generateImages(
            from: [ImageService.ImageSuggestionInput(excerpt: "E", prompt: "P", sourceBlockId: 1)],
            model: ImageModel.gemini25Flash,
            apiKey: ""
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testGenerateImagesPartialFailures() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 2 {
                throw NSError(domain: "Test", code: 500, userInfo: nil)
            }
            let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            let response = """
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
            """
            return (HTTPURLResponse(url: URL(string: "https://google.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response.data(using: .utf8)!)
        }

        let suggestions = [
            ImageService.ImageSuggestionInput(excerpt: "E1", prompt: "P1", sourceBlockId: 1),
            ImageService.ImageSuggestionInput(excerpt: "E2", prompt: "P2", sourceBlockId: 2),
            ImageService.ImageSuggestionInput(excerpt: "E3", prompt: "P3", sourceBlockId: 3)
        ]

        let results = await imageService.generateImages(
            from: suggestions,
            model: ImageModel.gemini25Flash,
            apiKey: "test-key",
            maxConcurrent: 3
        )

        XCTAssertEqual(results.count, 2)
        let ids = Set(results.map { $0.sourceBlockId })
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.isSubset(of: Set([1, 2, 3])))
    }

    func testGenerateImagesAllFailures() async throws {
        MockURLProtocol.stubError = NSError(domain: "Test", code: 500, userInfo: nil)

        let suggestions = [
            ImageService.ImageSuggestionInput(excerpt: "E1", prompt: "P1", sourceBlockId: 1),
            ImageService.ImageSuggestionInput(excerpt: "E2", prompt: "P2", sourceBlockId: 2)
        ]

        let results = await imageService.generateImages(
            from: suggestions,
            model: ImageModel.gemini25Flash,
            apiKey: "test-key"
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testGenerateImagesConcurrentLimit() async throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let response = """
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
        """
        MockURLProtocol.stubResponseData = response.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let suggestions = (0..<10).map { i in
            ImageService.ImageSuggestionInput(excerpt: "Excerpt \(i)", prompt: "Prompt \(i)", sourceBlockId: i)
        }

        let results = await imageService.generateImages(
            from: suggestions,
            model: ImageModel.gemini25Flash,
            apiKey: "test-key",
            maxConcurrent: 3
        )

        XCTAssertEqual(results.count, 10)
    }

    func testGenerateImagesRespectsOrder() async throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let response = """
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
        """
        MockURLProtocol.stubResponseData = response.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let suggestions = [
            ImageService.ImageSuggestionInput(excerpt: "E1", prompt: "P1", sourceBlockId: 100),
            ImageService.ImageSuggestionInput(excerpt: "E2", prompt: "P2", sourceBlockId: 200),
            ImageService.ImageSuggestionInput(excerpt: "E3", prompt: "P3", sourceBlockId: 300)
        ]

        let results = await imageService.generateImages(
            from: suggestions,
            model: ImageModel.gemini25Flash,
            apiKey: "test-key"
        )

        XCTAssertEqual(results.map { $0.sourceBlockId }, [100, 200, 300])
    }

    // MARK: - Helper Methods

    private func createMinimalPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    }

    private func createPNGWithIEND() -> Data {
        createMinimalPNG()
    }

    private func createPNGWithoutIEND() -> Data {
        var data = Data()
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(contentsOf: [0x08, 0x02])
        data.append(contentsOf: [0x00, 0x00, 0x00])
        data.append(contentsOf: [0x90, 0x77, 0x53, 0xDE])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0A])
        data.append(contentsOf: [0x49, 0x44, 0x41, 0x54])
        data.append(contentsOf: [0x08, 0xD7, 0x63, 0xF8, 0x0F, 0x00, 0x00, 0x01, 0x01, 0x00, 0x05, 0x18, 0xD8])
        data.append(contentsOf: [0x4D, 0xAE])
        return data
    }
}
