import XCTest
@testable import Reverie

@MainActor
final class ImageServicePromptFeedbackTests: XCTestCase {
    private var imageService: ImageService!
    private var mockSession: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        imageService = ImageService(session: mockSession)
    }

    override func tearDown() async throws {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    func testGenerateImageBlockedPromptFeedbackReturnsRefusalReason() async throws {
        MockURLProtocol.stubResponseData = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        do {
            _ = try await imageService.generateImage(
                prompt: "Prompt",
                model: .gemini25Flash,
                apiKey: "test-key"
            )
            XCTFail("Expected blocked prompt feedback to surface as a refusal")
        } catch {
            guard case .noImageReturned(let reason)? = error as? ImageService.ImageError else {
                return XCTFail("Expected noImageReturned error, got: \(error)")
            }

            XCTAssertTrue(reason.contains("blocked"))
            XCTAssertTrue(reason.contains("SAFETY"))
        }
    }

    func testGenerateImagesBlockedPromptFeedbackClassifiesAsRefused() async throws {
        MockURLProtocol.stubResponseData = #"{"promptFeedback":{"blockReason":"OTHER"}}"#.data(using: .utf8)
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://google.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let results = await imageService.generateImages(
            from: [.init(excerpt: "Excerpt", prompt: "Prompt", sourceBlockId: 7, aspectRatio: "9:16")],
            model: .gemini25Flash,
            apiKey: "test-key"
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .refused)
        XCTAssertEqual(results[0].aspectRatio, "9:16")
        XCTAssertEqual(results[0].sourceBlockId, 7)
        XCTAssertTrue(results[0].failureReason?.contains("blocked") == true)
    }
}
