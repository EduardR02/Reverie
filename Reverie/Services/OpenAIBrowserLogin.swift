import CryptoKit
import Darwin
import Foundation
import Security

struct OpenAIBrowserAuthorization: Sendable {
    let code: String
    let verifier: String
}

enum OpenAIBrowserLogin {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirectURI = "http://localhost:1455/auth/callback"

    static func authorize(
        openURL: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> OpenAIBrowserAuthorization {
        let verifier = try randomValue()
        let server = OpenAIBrowserCallbackServer(port: 1455, state: try randomValue())
        return try await authorize(using: server, verifier: verifier) { url, _ in
            try await openURL(url)
        }
    }

    // The injected listener is the I/O boundary for ephemeral-port tests.
    // Production always constructs the fixed, allowlisted listener above.
    static func authorize(
        using server: OpenAIBrowserCallbackServer,
        verifier: String,
        openURL: @escaping @Sendable (URL, UInt16) async throws -> Void
    ) async throws -> OpenAIBrowserAuthorization {
        try await withTaskCancellationHandler {
            do {
                let port = try await server.start()
                try Task.checkCancellation()
                do {
                    try await openURL(authorizationURL(state: server.state, verifier: verifier), port)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw OpenAISubscriptionAuthError.browserUnavailable
                }
                try Task.checkCancellation()
                let code = try await server.authorizationCode()
                try Task.checkCancellation()
                return OpenAIBrowserAuthorization(code: code, verifier: verifier)
            } catch {
                await server.close()
                throw error
            }
        } onCancel: {
            server.cancel()
        }
    }

    static func authorizationURL(state: String, verifier: String) -> URL {
        var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "reverie")
        ]
        return components.url!
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// All mutable state and socket operations are confined to `queue`.
final class OpenAIBrowserCallbackServer: @unchecked Sendable {
    private struct Request {
        let id = UUID()
        var data = Data()
    }

    let state: String
    private let requestedPort: UInt16
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "Reverie.OpenAIBrowserCallback")
    private var port: UInt16?
    private var sources: [Int32: DispatchSourceRead] = [:]
    private var connections: [Int32: Request] = [:]
    private var waiter: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var deadline: DispatchWorkItem?

    init(port: UInt16, state: String, timeout: TimeInterval = 5 * 60) {
        self.requestedPort = port
        self.state = state
        self.timeout = timeout
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(throwing: result.failure ?? CancellationError())
                        return
                    }
                    do {
                        let ipv4 = try Self.bindIPv4(port: self.requestedPort)
                        let ipv6: Int32
                        let port: UInt16
                        do {
                            port = try Self.boundPort(ipv4)
                            ipv6 = try Self.bindIPv6(port: port)
                        } catch {
                            Darwin.close(ipv4)
                            throw error
                        }
                        self.port = port
                        self.monitor(ipv4) { [weak self] in self?.accept(ipv4) }
                        self.monitor(ipv6) { [weak self] in self?.accept(ipv6) }
                        let deadline = DispatchWorkItem { [weak self] in
                            self?.finish(.failure(OpenAISubscriptionAuthError.signInTimedOut))
                        }
                        self.deadline = deadline
                        self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
                        continuation.resume(returning: port)
                    } catch {
                        self.finish(.failure(OpenAISubscriptionAuthError.callbackUnavailable))
                        continuation.resume(throwing: OpenAISubscriptionAuthError.callbackUnavailable)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func authorizationCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result, self.sources.isEmpty {
                        continuation.resume(with: result)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeWaiters.append(continuation)
                self.finish(.failure(CancellationError()))
                self.deliverResult()
            }
        }
    }

    private func monitor(_ fd: Int32, handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { [weak self] in
            Darwin.close(fd)
            self?.sources.removeValue(forKey: fd)
            self?.deliverResult()
        }
        sources[fd] = source
        source.resume()
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel()
        deadline = nil
        connections.removeAll()
        for source in sources.values { source.cancel() }
        deliverResult()
    }

    private func deliverResult() {
        guard let result, sources.isEmpty else { return }
        waiter?.resume(with: result)
        waiter = nil
        for continuation in closeWaiters { continuation.resume() }
        closeWaiters.removeAll()
    }

    private func closeSocket(_ fd: Int32) {
        connections.removeValue(forKey: fd)
        sources[fd]?.cancel()
    }

    private func accept(_ listener: Int32) {
        guard result == nil else { return }
        for _ in 0..<32 {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    finish(.failure(OpenAISubscriptionAuthError.callbackUnavailable))
                }
                return
            }
            guard connections.count < 16, (try? Self.configure(fd)) != nil else {
                Darwin.close(fd)
                continue
            }
            let request = Request()
            connections[fd] = request
            monitor(fd) { [weak self] in self?.receive(fd) }
            // A local client cannot keep an incomplete request alive for the whole login.
            let requestID = request.id
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.connections[fd]?.id == requestID else { return }
                self.closeSocket(fd)
            }
        }
    }

    private func receive(_ fd: Int32) {
        guard result == nil, var request = connections.removeValue(forKey: fd) else { return }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4_096) { bytes in
            while true {
                let count = Darwin.recv(fd, bytes.baseAddress, bytes.count, 0)
                if count > 0 {
                    request.data.append(bytes.baseAddress!, count: count)
                    guard request.data.count <= 16_384 else {
                        respond(fd, status: "431 Request Header Fields Too Large")
                        return
                    }
                    if let end = request.data.range(of: Data("\r\n\r\n".utf8)) {
                        handle(Data(request.data[..<end.lowerBound]), fd: fd)
                        return
                    }
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    connections[fd] = request
                    return
                } else {
                    closeSocket(fd)
                    return
                }
            }
        }
    }

    private func handle(_ data: Data, fd: Int32) {
        guard let header = String(data: data, encoding: .utf8) else {
            respond(fd, status: "400 Bad Request")
            return
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET",
              request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            respond(fd, status: "400 Bad Request")
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                respond(fd, status: "400 Bad Request")
                return
            }
            let name = line[..<separator].lowercased()
            guard headers[name] == nil else {
                respond(fd, status: "400 Bad Request")
                return
            }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard let port, let host = headers["host"],
              host == "localhost:\(port)" || host == "127.0.0.1:\(port)" || host == "[::1]:\(port)",
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else {
            respond(fd, status: "400 Bad Request")
            return
        }
        let target = String(request[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let url = URLComponents(string: target), url.scheme == nil, url.host == nil,
              url.fragment == nil, url.percentEncodedPath == "/auth/callback" else {
            respond(fd, status: "404 Not Found")
            return
        }
        let rawQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard rawQuery.count == 2, url.percentEncodedQuery == String(rawQuery[1]) else {
            respond(fd, status: "400 Bad Request")
            return
        }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard let value = item.value, query[item.name] == nil else {
                respond(fd, status: "400 Bad Request")
                return
            }
            query[item.name] = value
        }
        guard query["state"] == state else {
            // Unrelated requests cannot terminate or satisfy the pending sign-in.
            respond(fd, status: "400 Bad Request")
            return
        }
        let outcome: Result<String, Error>
        if let error = query["error"] {
            outcome = .failure(error == "access_denied" && query["code"] == nil
                ? OpenAISubscriptionAuthError.accessDenied : OpenAISubscriptionAuthError.invalidResponse)
        } else if let code = query["code"], !code.isEmpty, code.utf8.count <= 8_192,
                  !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            outcome = .success(code)
        } else {
            outcome = .failure(OpenAISubscriptionAuthError.invalidResponse)
        }
        let message = outcome.failure == nil
            ? "Authorization received. Return to Reverie to finish signing in."
            : "Authorization could not be completed. Return to Reverie."
        respond(fd, status: outcome.failure == nil ? "200 OK" : "400 Bad Request", message: message)
        finish(outcome)
    }

    private func respond(_ fd: Int32, status: String, message: String = "This request cannot complete sign-in.") {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n\r\n"
        let response = Data(header.utf8) + body
        response.withUnsafeBytes { bytes in
            // Best-effort delivery must never let a nonreading browser retain
            // the callback listener. The sockets are nonblocking.
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        Darwin.shutdown(fd, SHUT_WR)
        closeSocket(fd)
    }

    private static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw OpenAISubscriptionAuthError.callbackUnavailable
        }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw OpenAISubscriptionAuthError.callbackUnavailable
        }
    }

    private static func makeListener(family: Int32) throws -> Int32 {
        let fd = Darwin.socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OpenAISubscriptionAuthError.callbackUnavailable }
        do {
            try configure(fd)
            var enabled: Int32 = 1
            // Reclaim TIME_WAIT addresses without SO_REUSEPORT's concurrent listeners.
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw OpenAISubscriptionAuthError.callbackUnavailable
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func bindIPv4(port: UInt16) throws -> Int32 {
        let fd = try makeListener(family: AF_INET)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw OpenAISubscriptionAuthError.callbackUnavailable
        }
        return fd
    }

    private static func bindIPv6(port: UInt16) throws -> Int32 {
        let fd = try makeListener(family: AF_INET6)
        var enabled: Int32 = 1
        guard setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            throw OpenAISubscriptionAuthError.callbackUnavailable
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard status == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw OpenAISubscriptionAuthError.callbackUnavailable
        }
        return fd
    }

    private static func boundPort(_ fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard status == 0 else { throw OpenAISubscriptionAuthError.callbackUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}

private extension Result where Success == String, Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
