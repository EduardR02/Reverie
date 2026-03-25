import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ChapterAnalyzerAspectRatioTests: XCTestCase {
    private var analyzer: ChapterAnalyzer!
    private var database: DatabaseService!
    private var settings: UserSettings!

    override func setUp() async throws {
        try await super.setUp()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        settings = UserSettings()
        settings.googleAPIKey = "mock-key"

        database = try DatabaseService(dbQueue: DatabaseQueue())
        analyzer = ChapterAnalyzer(
            llm: LLMService(session: mockSession),
            imageService: ImageService(session: mockSession),
            database: database,
            settings: settings
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    func testGenerateImagesPersistsSuggestedAspectRatio() async throws {
        var capturedAspectRatio: String?
        MockURLProtocol.requestHandler = { request in
            let json = try self.requestJSON(from: request)
            let generationConfig = json["generationConfig"] as? [String: Any]
            let imageConfig = generationConfig?["imageConfig"] as? [String: Any]
            capturedAspectRatio = imageConfig?["aspectRatio"] as? String

            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":{"message":"blocked by policy","code":400}}"#.data(using: .utf8)!
            return (response, data)
        }

        var book = Book(title: "Book", author: "Author", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Content</p>")
        try database.saveChapter(&chapter)

        var generated: [GeneratedImage] = []
        let stream = analyzer.generateImages(
            suggestions: [.init(excerpt: "Excerpt", sourceBlockId: 1, aspectRatio: "9:16")],
            book: book,
            chapter: chapter
        )

        for try await image in stream {
            generated.append(image)
        }

        XCTAssertEqual(capturedAspectRatio, "9:16")
        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(generated[0].aspectRatio, "9:16")

        let persisted = try database.fetchImages(for: chapter)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].aspectRatio, "9:16")
    }

    func testRetryImageUsesStoredAspectRatio() async throws {
        var capturedAspectRatio: String?
        MockURLProtocol.requestHandler = { request in
            let json = try self.requestJSON(from: request)
            let generationConfig = json["generationConfig"] as? [String: Any]
            let imageConfig = generationConfig?["imageConfig"] as? [String: Any]
            capturedAspectRatio = imageConfig?["aspectRatio"] as? String

            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":{"message":"retry still blocked","code":400}}"#.data(using: .utf8)!
            return (response, data)
        }

        var book = Book(title: "Book", author: "Author", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Content</p>")
        try database.saveChapter(&chapter)

        var image = GeneratedImage(
            chapterId: chapter.id!,
            excerpt: "Excerpt",
            prompt: "Wrapped prompt",
            imagePath: "",
            sourceBlockId: 1,
            aspectRatio: "1:1",
            status: .failed,
            failureReason: "Old failure"
        )
        try database.saveImage(&image)

        let updated = try await analyzer.retryImage(image, book: book, chapter: chapter)

        XCTAssertEqual(capturedAspectRatio, "1:1")
        XCTAssertEqual(updated.aspectRatio, "1:1")

        let persisted = try database.fetchImages(for: chapter)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].aspectRatio, "1:1")
    }

    func testRewriteAndRetryImageUsesStoredAspectRatio() async throws {
        var requestCount = 0
        var capturedAspectRatio: String?

        MockURLProtocol.requestHandler = { request in
            requestCount += 1

            if requestCount == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = #"{"candidates":[{"content":{"parts":[{"text":"Rewritten prompt"}]}}]}"#.data(using: .utf8)!
                return (response, data)
            }

            let json = try self.requestJSON(from: request)
            let generationConfig = json["generationConfig"] as? [String: Any]
            let imageConfig = generationConfig?["imageConfig"] as? [String: Any]
            capturedAspectRatio = imageConfig?["aspectRatio"] as? String

            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":{"message":"rewrite retry still blocked","code":400}}"#.data(using: .utf8)!
            return (response, data)
        }

        var book = Book(title: "Book", author: "Author", epubPath: "")
        try database.saveBook(&book)
        var chapter = Chapter(bookId: book.id!, index: 0, title: "Chapter", contentHTML: "<p>Content</p>")
        try database.saveChapter(&chapter)

        var image = GeneratedImage(
            chapterId: chapter.id!,
            excerpt: "Excerpt",
            prompt: "Wrapped prompt",
            imagePath: "",
            sourceBlockId: 1,
            aspectRatio: "9:16",
            status: .failed,
            failureReason: "Old failure"
        )
        try database.saveImage(&image)

        let updated = try await analyzer.rewriteAndRetryImage(image, book: book, chapter: chapter)

        XCTAssertEqual(capturedAspectRatio, "9:16")
        XCTAssertEqual(updated.prompt, "Rewritten prompt")
        XCTAssertEqual(updated.aspectRatio, "9:16")

        let persisted = try database.fetchImages(for: chapter)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].prompt, "Rewritten prompt")
        XCTAssertEqual(persisted[0].aspectRatio, "9:16")
    }

    private func requestJSON(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(requestBodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func requestBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let chunkSize = 4096
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var data = Data()

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            if read <= 0 {
                break
            }
            data.append(contentsOf: buffer[0..<read])
        }

        return data.isEmpty ? nil : data
    }
}
