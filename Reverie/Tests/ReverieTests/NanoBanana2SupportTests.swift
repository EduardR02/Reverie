import XCTest
@testable import Reverie

final class NanoBanana2SupportTests: XCTestCase {
    func testImageModelGemini31FlashProperties() {
        XCTAssertEqual(ImageModel.gemini31Flash.rawValue, "Gemini 3.1 Flash")
        XCTAssertEqual(ImageModel.gemini31Flash.description, "Nano Banana 2")
        XCTAssertEqual(ImageModel.gemini31Flash.apiModel, "gemini-3.1-flash-image-preview")
        XCTAssertEqual(ImageModel.gemini31Flash.detailDescription, "Fast, high quality, up to 4K")
    }

    func testImagePricingGemini31Flash() {
        let pricing = PricingCatalog.imagePricing(for: .gemini31Flash)
        XCTAssertEqual(pricing.inputPerMToken, 0.5)
        XCTAssertNil(pricing.outputPerMToken)
        XCTAssertEqual(pricing.outputPerImage, 0.10)
    }

    func testGemini31FlashMatchesGemini3ImageSizeCheck() {
        XCTAssertTrue(ImageModel.gemini31Flash.apiModel.contains("gemini-3"))
    }
}

@MainActor
final class NanoBanana2ImageServiceRequestTests: XCTestCase {
    var imageService: ImageService!
    var mockSession: URLSession!

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

    func testGenerateImageIncludesResponseModalitiesForGemini25Flash() async throws {
        var generationConfig: [String: Any]?
        let responseData = makeImageResponseData()

        MockURLProtocol.requestHandler = { request in
            let requestBody = self.requestBodyData(from: request)
            let json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            generationConfig = json?["generationConfig"] as? [String: Any]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        _ = try await imageService.generateImage(
            prompt: "Test prompt",
            model: .gemini25Flash,
            apiKey: "test-key",
            imageResolution: "4K"
        )

        let config = try XCTUnwrap(generationConfig)
        XCTAssertEqual(config["responseModalities"] as? [String], ["IMAGE", "TEXT"])
        let imageConfig = try XCTUnwrap(config["imageConfig"] as? [String: Any])
        XCTAssertNil(imageConfig["imageSize"])
    }

    func testGenerateImageIncludesResponseModalitiesAndImageSizeForGemini31Flash() async throws {
        var generationConfig: [String: Any]?
        let responseData = makeImageResponseData()

        MockURLProtocol.requestHandler = { request in
            let requestBody = self.requestBodyData(from: request)
            let json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            generationConfig = json?["generationConfig"] as? [String: Any]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        _ = try await imageService.generateImage(
            prompt: "Test prompt",
            model: .gemini31Flash,
            apiKey: "test-key",
            imageResolution: "4K"
        )

        let config = try XCTUnwrap(generationConfig)
        XCTAssertEqual(config["responseModalities"] as? [String], ["IMAGE", "TEXT"])
        let imageConfig = try XCTUnwrap(config["imageConfig"] as? [String: Any])
        XCTAssertEqual(imageConfig["imageSize"] as? String, "4K")
    }

    private func makeImageResponseData() -> Data {
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
        return response.data(using: .utf8)!
    }

    private func requestBodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
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

        return data
    }
}
