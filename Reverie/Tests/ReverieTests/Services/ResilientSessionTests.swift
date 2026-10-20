import XCTest
@testable import Reverie

final class ResilientSessionTests: XCTestCase {
    var mockSession: URLSession!
    var resilientSession: ResilientSession!
    
    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        resilientSession = ResilientSession(session: mockSession)
        
        // Reset MockURLProtocol state
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
    }

    @MainActor
    override func tearDown() async throws {
        mockSession.invalidateAndCancel()
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubResponse = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
        try await super.tearDown()
    }

    @MainActor
    func testNormalRequestSuccess() async throws {
        let expectedData = "Success".data(using: .utf8)!
        MockURLProtocol.stubResponseData = expectedData
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let (data, _) = try await resilientSession.data(for: request)
        
        XCTAssertEqual(data, expectedData)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }
    
    @MainActor
    func testOtherErrorsDoNotRetry() async throws {
        let otherError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        MockURLProtocol.stubError = otherError
        
        let request = URLRequest(url: URL(string: "https://example.com")!)
        
        do {
            _ = try await resilientSession.data(for: request)
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut)
        }
        
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    @MainActor
    func testBytesRequestSuccess() async throws {
        let expectedData = "Success".data(using: .utf8)!
        MockURLProtocol.stubResponseData = expectedData
        MockURLProtocol.stubResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let (bytes, _) = try await resilientSession.bytes(for: request)
        
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        
        XCTAssertEqual(data, expectedData)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    @MainActor
    func testPrivateRequestsDoNotSendOrPersistAmbientSessionCookies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let cookies = try XCTUnwrap(configuration.httpCookieStorage)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "subscription-fixture.invalid", .path: "/", .name: "ambient", .value: "fixture-only"
        ]))
        cookies.setCookie(cookie)
        let client = ResilientSession(configuration: configuration)
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "returned=fixture-only; Path=/"]
            )!
            return (response, Data("Private answer".utf8))
        }
        let request = URLRequest(url: URL(string: "https://subscription-fixture.invalid/responses")!)
        _ = try await client.data(for: request)
        _ = try await client.data(for: request)
        XCTAssertEqual(cookies.cookies?.map(\.name), ["ambient"])
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }
}
