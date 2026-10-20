import Darwin
import Foundation
import XCTest
@testable import Reverie

@MainActor
final class OpenAIBrowserLoginTests: XCTestCase {
    func testPKCEUsesRFC7636S256VectorAndURLDoesNotExposeVerifier() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let state = "state+with/special?characters=&"
        let url = OpenAIBrowserLogin.authorizationURL(state: state, verifier: verifier)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(items.count, values.count)
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(values["state"], state)
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertFalse(url.absoluteString.contains(verifier))
        XCTAssertNil(values["code_verifier"])
        XCTAssertNil(values["code"])
    }

    func testRandomValuesMeetPKCEAndStateEntropyEncodingBoundaries() throws {
        let value = try OpenAIBrowserLogin.randomValue()
        XCTAssertEqual(value.utf8.count, 43) // 256 random bits without base64 padding.
        XCTAssertTrue(value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        })
    }

    func testBrowserOpensOnceAfterBothLoopbackListenersAreReadyAndReturnsCodeAndVerifier() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let opened = BrowserLoginOpenRecorder()
        let authorization = try await OpenAIBrowserLogin.authorize(using: server, verifier: "original-verifier") { url, port in
            await opened.record(url, port: port)
            // Both connections must work during the browser-open boundary, not later.
            let ipv6 = try await Self.request(port: port, path: "/favicon.ico", host: "[::1]")
            XCTAssertEqual(ipv6.status, 404)
            let callback = try await Self.request(port: port, path: "/auth/callback?state=expected-state&code=secret%2Bcode%2F%3D")
            XCTAssertEqual(callback.status, 200)
            XCTAssertFalse(callback.body.contains("secret"))
            XCTAssertFalse(callback.body.contains("expected-state"))
            XCTAssertFalse(callback.body.lowercased().contains("signed in"))
            XCTAssertEqual(callback.cacheControl, "no-store")
        }
        XCTAssertEqual(authorization.code, "secret+code/=")
        XCTAssertEqual(authorization.verifier, "original-verifier")
        let observations = await opened.values
        XCTAssertEqual(observations.count, 1)
        let port = try XCTUnwrap(observations.first?.port)
        try await Self.assertPortReleased(port)
    }

    func testUnrelatedMismatchedAndDuplicateCallbacksCannotCompleteOrTerminateSignIn() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let port = try await server.start()
        do {
            let rejected = [
                ("/favicon.ico?state=expected-state&code=wrong", 404),
                ("/auth/callback/extra?state=expected-state&code=wrong", 404),
                ("/auth/callback?state=wrong-state&code=wrong", 400),
                ("/auth/callback?code=wrong", 400),
                ("/auth/callback?state=expected-state&state=expected-state&code=wrong", 400),
                ("/auth/callback?state=expected-state&code=wrong&code=other", 400),
                ("/auth/callback?state=expected-state&%63ode=wrong&code=other", 400)
            ]
            for (path, status) in rejected {
                let response = try await Self.request(port: port, path: path)
                XCTAssertEqual(response.status, status)
                XCTAssertFalse(response.body.contains("expected-state"))
                XCTAssertFalse(response.body.contains("wrong"))
            }
            let wrongHost = try await Self.request(port: port, path: "/auth/callback?state=expected-state&code=wrong", hostHeader: "attacker.invalid")
            XCTAssertEqual(wrongHost.status, 400)
            let wrongMethod = try await Self.request(port: port, path: "/auth/callback?state=expected-state&code=wrong", method: "POST")
            XCTAssertEqual(wrongMethod.status, 400)
            let accepted = try await Self.request(port: port, path: "/auth/callback?state=expected-state&code=accepted")
            XCTAssertEqual(accepted.status, 200)
            let code = try await server.authorizationCode()
            XCTAssertEqual(code, "accepted")
        } catch {
            await server.close()
            throw error
        }
        try await Self.assertPortReleased(port)
    }

    func testMatchingDenialNeverReturnsCredentialsAndDoesNotReflectProviderDescription() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let port = try await server.start()
        let response = try await Self.request(port: port, path: "/auth/callback?state=expected-state&error=access_denied&error_description=private-provider-detail")
        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(response.body.contains("private-provider-detail"))
        await Self.expect(.accessDenied) { _ = try await server.authorizationCode() }
        try await Self.assertPortReleased(port)
    }

    func testMatchingMalformedAndAmbiguousCallbacksFailWithoutCredentials() async throws {
        for query in ["code=", "error=server_error", "error=access_denied&code=secret", "code=bad%00code"] {
            let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
            let port = try await server.start()
            let response = try await Self.request(port: port, path: "/auth/callback?state=expected-state&\(query)")
            XCTAssertEqual(response.status, 400)
            XCTAssertFalse(response.body.contains("secret"))
            await Self.expect(.invalidResponse) { _ = try await server.authorizationCode() }
            try await Self.assertPortReleased(port)
        }
    }

    func testCancellingCallbackWaitReleasesBothPortsAndNeverYieldsCode() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let port = try await server.start()
        let wait = Task { try await server.authorizationCode() }
        wait.cancel()
        do {
            _ = try await wait.value
            XCTFail("A cancelled callback must not yield credentials")
        } catch is CancellationError {
        }
        try await Self.assertPortReleased(port)
    }

    func testCancellingBrowserAuthorizationClosesListener() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let opened = BrowserLoginOpenRecorder()
        let login = Task {
            try await OpenAIBrowserLogin.authorize(using: server, verifier: "verifier") { url, port in
                await opened.record(url, port: port)
            }
        }
        let port = await opened.waitForPort()
        login.cancel()
        do {
            _ = try await login.value
            XCTFail("Cancelled authorization must not yield credentials")
        } catch is CancellationError {
        }
        try await Self.assertPortReleased(port)
    }

    func testBrowserOpenFailureIsRedactedAndReleasesPort() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let opened = BrowserLoginOpenRecorder()
        await Self.expect(.browserUnavailable) {
            _ = try await OpenAIBrowserLogin.authorize(using: server, verifier: "verifier") { url, port in
                await opened.record(url, port: port)
                throw BrowserLoginTestError.browserFailure
            }
        }
        let observations = await opened.values
        XCTAssertEqual(observations.count, 1)
        try await Self.assertPortReleased(XCTUnwrap(observations.first?.port))
    }

    func testOccupiedCallbackPortFailsBeforeOpeningBrowserAndDoesNotDisturbOwner() async throws {
        let owner = OpenAIBrowserCallbackServer(port: 0, state: "owner-state")
        let port = try await owner.start()
        let contender = OpenAIBrowserCallbackServer(port: port, state: "contender-state")
        let opened = BrowserLoginOpenRecorder()
        await Self.expect(.callbackUnavailable) {
            _ = try await OpenAIBrowserLogin.authorize(using: contender, verifier: "verifier") { url, port in
                await opened.record(url, port: port)
            }
        }
        let observations = await opened.values
        XCTAssertTrue(observations.isEmpty)
        let response = try await Self.request(port: port, path: "/auth/callback?state=owner-state&code=owner-code")
        XCTAssertEqual(response.status, 200)
        let code = try await owner.authorizationCode()
        XCTAssertEqual(code, "owner-code")
        try await Self.assertPortReleased(port)
    }

    func testTimeoutNeverYieldsCredentialsAndReleasesPort() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state", timeout: 1)
        let port = try await server.start()
        await Self.expect(.signInTimedOut) { _ = try await server.authorizationCode() }
        try await Self.assertPortReleased(port)
    }

    func testAlreadyCancelledAuthorizationNeverOpensBrowser() async throws {
        let server = OpenAIBrowserCallbackServer(port: 0, state: "expected-state")
        let opened = BrowserLoginOpenRecorder()
        let login = Task {
            try await OpenAIBrowserLogin.authorize(using: server, verifier: "verifier") { url, port in
                await opened.record(url, port: port)
            }
        }
        // This task inherits MainActor, so it cannot run before this cancellation.
        login.cancel()
        do {
            _ = try await login.value
            XCTFail("Already-cancelled authorization must not yield credentials")
        } catch is CancellationError {
        }
        let observations = await opened.values
        XCTAssertTrue(observations.isEmpty)
    }

    func testOccupiedIPv6CompanionReleasesPartiallyBoundIPv4Listener() async throws {
        let (blocker, port) = try Self.occupyIPv6()
        let contender = OpenAIBrowserCallbackServer(port: port, state: "expected-state")
        await Self.expect(.callbackUnavailable) { _ = try await contender.start() }
        Darwin.close(blocker)
        try await Self.assertPortReleased(port)
    }

    private nonisolated static func occupyIPv6() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserLoginTestError.socketFailure }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        var enabled: Int32 = 1
        let option = setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &size) }
        }
        guard option == 0, bound == 0, named == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw BrowserLoginTestError.socketFailure
        }
        return (fd, UInt16(bigEndian: address.sin6_port))
    }

    private nonisolated static func request(
        port: UInt16, path: String, host: String = "127.0.0.1",
        hostHeader: String? = nil, method: String = "GET"
    ) async throws -> BrowserLoginHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://\(host):\(port)\(path)")))
        request.httpMethod = method
        request.timeoutInterval = 5
        if let hostHeader { request.setValue(hostHeader, forHTTPHeaderField: "Host") }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return BrowserLoginHTTPResponse(status: http.statusCode, body: String(decoding: data, as: UTF8.self),
                                        cacheControl: http.value(forHTTPHeaderField: "Cache-Control"))
    }

    private nonisolated static func assertPortReleased(_ port: UInt16) async throws {
        let replacement = OpenAIBrowserCallbackServer(port: port, state: "replacement-state")
        _ = try await replacement.start()
        await replacement.close()
    }

    private nonisolated static func expect(
        _ expected: OpenAISubscriptionAuthError,
        operation: @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected a redacted authorization failure")
        } catch {
            XCTAssertEqual(error as? OpenAISubscriptionAuthError, expected)
        }
    }
}

private struct BrowserLoginHTTPResponse: Sendable {
    let status: Int
    let body: String
    let cacheControl: String?
}

private enum BrowserLoginTestError: Error {
    case browserFailure
    case socketFailure
}

private actor BrowserLoginOpenRecorder {
    struct Observation: Sendable {
        let url: URL
        let port: UInt16
    }

    private(set) var values: [Observation] = []
    private var portWaiter: CheckedContinuation<UInt16, Never>?

    func record(_ url: URL, port: UInt16) {
        values.append(Observation(url: url, port: port))
        portWaiter?.resume(returning: port)
        portWaiter = nil
    }

    func waitForPort() async -> UInt16 {
        if let first = values.first { return first.port }
        return await withCheckedContinuation { portWaiter = $0 }
    }
}
