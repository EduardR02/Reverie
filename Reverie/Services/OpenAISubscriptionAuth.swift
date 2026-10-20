import Foundation
import Security
import LocalAuthentication
import Synchronization

/// Subscription access uses the Codex/ChatGPT backend, not the billable Platform API.
enum OpenAIAuthenticationMode: String, Codable, CaseIterable, Hashable, Sendable, CustomStringConvertible {
    case apiKey
    case chatGPTSubscription

    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .chatGPTSubscription: return "ChatGPT Subscription"
        }
    }

    var description: String { displayName }
}

struct OpenAISubscriptionCredential: Sendable {
    let accessToken: String
    let accountID: String
    let residency: String?
}

enum OpenAISubscriptionAuthError: Error, LocalizedError, Equatable {
    case notConnected
    case signInInProgress
    case signInRequired
    case invalidResponse
    case network
    case requestFailed(Int)
    case callbackUnavailable
    case signInTimedOut
    case browserUnavailable
    case accessDenied
    case credentialStorage

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Sign in with ChatGPT in Settings to use subscription access."
        case .signInInProgress: return "Finish or cancel the ChatGPT sign-in already in progress."
        case .signInRequired: return "Your ChatGPT session is no longer valid. Sign in again in Settings."
        case .invalidResponse: return "ChatGPT returned an invalid sign-in response. Try signing in again."
        case .network: return "Could not reach ChatGPT. Check your connection and try again."
        case .requestFailed(let status): return "ChatGPT sign-in failed (HTTP \(status)). Try again."
        case .callbackUnavailable: return "Could not start the local ChatGPT sign-in callback. Close other sign-in attempts and try again."
        case .signInTimedOut: return "ChatGPT sign-in timed out. Try signing in again."
        case .browserUnavailable: return "Could not open your browser for ChatGPT sign-in. Check your default browser and try again."
        case .accessDenied: return "ChatGPT sign-in was declined."
        case .credentialStorage: return "Could not update the macOS Keychain. Subscription access is disabled until credentials can be saved or removed securely."
        }
    }
}

/// Narrow synchronous storage operations keep credential rotation and invalidation atomic in the actor.
protocol OpenAISubscriptionCredentialStore: Sendable {
    func read() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

struct OpenAISubscriptionKeychainStore: OpenAISubscriptionCredentialStore {
    // SecItem's native login-Keychain backend also supports local/ad-hoc app builds.
    // Data-protection access groups would require a provisioned signing identity.
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.reverie.openai.subscription",
            kSecAttrAccount as String: "chatgpt"
        ]
    }

    static var containsCredential: Bool {
        // Request only existence, never token data or an authentication prompt.
        var query = Self.query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read() throws -> Data? {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OpenAISubscriptionAuthError.credentialStorage
        }
        return data
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = Self.query.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw OpenAISubscriptionAuthError.credentialStorage
            }
        } else if status != errSecSuccess {
            throw OpenAISubscriptionAuthError.credentialStorage
        }
    }

    func delete() throws {
        let status = SecItemDelete(Self.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAISubscriptionAuthError.credentialStorage
        }
    }
}

/// The auth endpoints carry secrets in request bodies, so redirects are forbidden here too.
private final class OpenAISubscriptionHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = OpenAISubscriptionHTTPClient()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let response = response as? HTTPURLResponse else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        return (data, response)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor OpenAISubscriptionAuth {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias BrowserAuthorize = @Sendable (@escaping @Sendable (URL) async throws -> Void) async throws -> OpenAIBrowserAuthorization

    static let shared = OpenAISubscriptionAuth()
    nonisolated static let sessionDidChange = Notification.Name("Reverie.OpenAISubscriptionSessionDidChange")
    nonisolated static var isConnected: Bool { OpenAISubscriptionKeychainStore.containsCredential }

    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    /// This is the only persisted representation. It is written exclusively to Keychain.
    struct StoredTokens: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let accountID: String?

        init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.accountID = accountID
        }
    }

    private struct SessionTokens: Sendable {
        let stored: StoredTokens
        let credential: OpenAISubscriptionCredential
    }

    private let store: any OpenAISubscriptionCredentialStore
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let browserAuthorize: BrowserAuthorize
    private nonisolated let revision = Mutex<UInt64>(0)
    nonisolated var sessionRevision: UInt64 { revision.withLock { $0 } }
    private var cached: SessionTokens?
    private var lastRefreshedCredential: OpenAISubscriptionCredential?
    private var generation: UInt64 = 0
    private var invalidated = false
    private var refreshTask: Task<OpenAISubscriptionCredential, Error>?
    private var loginTask: Task<Void, Error>?

    init(
        store: any OpenAISubscriptionCredentialStore = OpenAISubscriptionKeychainStore(),
        transport: @escaping Transport = { try await OpenAISubscriptionHTTPClient.shared.send($0) },
        now: @escaping @Sendable () -> Date = { Date() },
        browserAuthorize: @escaping BrowserAuthorize = { try await OpenAIBrowserLogin.authorize(openURL: $0) }
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.browserAuthorize = browserAuthorize
    }

    func credential() async throws -> OpenAISubscriptionCredential {
        try Task.checkCancellation()
        guard !invalidated else { throw OpenAISubscriptionAuthError.notConnected }
        guard loginTask == nil else { throw OpenAISubscriptionAuthError.signInInProgress }
        if let refreshTask {
            return try await awaitRefresh(refreshTask, generation: generation)
        }
        if cached == nil {
            do {
                guard let data = try store.read() else { throw OpenAISubscriptionAuthError.notConnected }
                let stored = try JSONDecoder().decode(StoredTokens.self, from: data)
                cached = try Self.sessionTokens(stored)
            } catch let error as OpenAISubscriptionAuthError {
                throw error
            } catch {
                throw OpenAISubscriptionAuthError.credentialStorage
            }
        }
        guard let tokens = cached else { throw OpenAISubscriptionAuthError.notConnected }
        // Refresh early so an access token does not expire while a request is being started.
        if tokens.stored.expiresAt.timeIntervalSince(now()) > 60 { return tokens.credential }
        return try await refreshedCredential(tokens)
    }

    /// Retry a rejected request only within its original account. Other requests may already
    /// have rotated the rejected token, in which case their persisted result is reused.
    func refreshCredential(rejectedAccessToken: String) async throws -> OpenAISubscriptionCredential {
        let rejectedClaims = try Self.accessTokenClaims(rejectedAccessToken)
        let rejectedAccount = try Self.accountIDClaim(rejectedClaims)
            ?? (cached?.credential.accessToken == rejectedAccessToken ? cached?.credential.accountID : nil)
            ?? (lastRefreshedCredential?.accessToken == rejectedAccessToken ? lastRefreshedCredential?.accountID : nil)
        let credential = try await credential()
        let boundAccount = rejectedAccount ?? (credential.accessToken == rejectedAccessToken ? credential.accountID : nil)
        guard credential.accountID == boundAccount else { throw OpenAISubscriptionAuthError.signInRequired }
        if credential.accessToken != rejectedAccessToken { return credential }
        guard let tokens = cached else { throw OpenAISubscriptionAuthError.notConnected }
        return try await refreshedCredential(tokens)
    }

    private func refreshedCredential(_ tokens: SessionTokens) async throws -> OpenAISubscriptionCredential {
        if let refreshTask {
            return try await awaitRefresh(refreshTask, generation: generation)
        }
        let currentGeneration = generation
        let task = Task { try await self.refresh(tokens, generation: currentGeneration) }
        refreshTask = task
        return try await awaitRefresh(task, generation: currentGeneration)
    }

    private func awaitRefresh(
        _ task: Task<OpenAISubscriptionCredential, Error>,
        generation expected: UInt64
    ) async throws -> OpenAISubscriptionCredential {
        do {
            let credential = try await task.value
            try ensureCurrent(expected)
            return credential
        } catch {
            // A cancelled waiter still observes cancellation when the shared grant fails.
            try ensureCurrent(expected)
            throw error
        }
    }

    /// Cancelling an individual credential waiter does not cancel another request's shared refresh.
    private func refresh(_ old: SessionTokens, generation expected: UInt64) async throws -> OpenAISubscriptionCredential {
        defer { if generation == expected { refreshTask = nil } }
        do {
            let tokens = try await tokenGrant([
                "grant_type": "refresh_token",
                "refresh_token": old.stored.refreshToken,
                "client_id": OpenAIBrowserLogin.clientID
            ], previous: old.stored)
            guard tokens.credential.accountID == old.credential.accountID else {
                throw OpenAISubscriptionAuthError.signInRequired
            }
            try commit(tokens, generation: expected)
            lastRefreshedCredential = old.credential
            return tokens.credential
        } catch OpenAISubscriptionAuthError.signInRequired {
            if generation == expected {
                invalidateSession()
                do { try store.delete() } catch { throw OpenAISubscriptionAuthError.credentialStorage }
            }
            throw OpenAISubscriptionAuthError.signInRequired
        }
    }

    func signIn(openURL: @escaping @Sendable (URL) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard loginTask == nil else { throw OpenAISubscriptionAuthError.signInInProgress }
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        let currentGeneration = generation
        let task = Task { try await self.performSignIn(generation: currentGeneration, openURL: openURL) }
        loginTask = task
        try await withTaskCancellationHandler {
            try await task.value
            try ensureCurrent(currentGeneration)
        } onCancel: {
            task.cancel()
            Task { await self.cancelSignIn(generation: currentGeneration) }
        }
    }

    func cancelSignIn() {
        cancelSignIn(generation: generation)
    }

    private func cancelSignIn(generation expected: UInt64) {
        guard generation == expected, loginTask != nil else { return }
        generation &+= 1
        loginTask?.cancel()
        loginTask = nil
    }

    /// Invalidate before touching storage: late network responses can never resurrect a signed-out session.
    func signOut() throws {
        generation &+= 1
        loginTask?.cancel()
        refreshTask?.cancel()
        loginTask = nil
        refreshTask = nil
        invalidateSession()
        do { try store.delete() } catch { throw OpenAISubscriptionAuthError.credentialStorage }
    }

    private func invalidateSession() {
        cached = nil
        lastRefreshedCredential = nil
        invalidated = true
        notifySessionChanged()
    }

    private func notifySessionChanged() {
        revision.withLock { $0 &+= 1 }
        NotificationCenter.default.post(name: Self.sessionDidChange, object: self)
    }

    private func performSignIn(
        generation expected: UInt64,
        openURL: @escaping @Sendable (URL) async throws -> Void
    ) async throws {
        defer { if generation == expected { loginTask = nil } }
        let authorization: OpenAIBrowserAuthorization
        do {
            authorization = try await browserAuthorize(openURL)
        } catch {
            try ensureCurrent(expected)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? OpenAISubscriptionAuthError { throw error }
            // Browser errors may contain the full authorization URL or callback secrets.
            throw OpenAISubscriptionAuthError.browserUnavailable
        }
        try ensureCurrent(expected)
        let tokens = try await tokenGrant([
            "grant_type": "authorization_code",
            "client_id": OpenAIBrowserLogin.clientID,
            "redirect_uri": OpenAIBrowserLogin.redirectURI,
            "code": authorization.code,
            "code_verifier": authorization.verifier
        ])
        try commit(tokens, generation: expected)
        lastRefreshedCredential = nil
        notifySessionChanged()
    }

    private func ensureCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func commit(_ tokens: SessionTokens, generation expected: UInt64) throws {
        try ensureCurrent(expected)
        do {
            try store.save(JSONEncoder().encode(tokens.stored))
        } catch {
            invalidateSession()
            // A rotated refresh token must not leave its obsolete predecessor usable.
            try? store.delete()
            throw OpenAISubscriptionAuthError.credentialStorage
        }
        cached = tokens
        invalidated = false
    }

    private func tokenGrant(_ fields: [String: String], previous: StoredTokens? = nil) async throws -> SessionTokens {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        // '+' is literal in URL queries but denotes a space in form bodies.
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let code = Self.errorCode(data)?.lowercased()
            if ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code)
                || response.statusCode == 401 {
                throw OpenAISubscriptionAuthError.signInRequired
            }
            throw OpenAISubscriptionAuthError.requestFailed(response.statusCode)
        }
        let object = try Self.jsonObject(data)
        guard let access = Self.nonempty(object["access_token"]) ?? previous?.accessToken,
              let refresh = Self.nonempty(object["refresh_token"]) ?? previous?.refreshToken else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        let claims = try Self.accessTokenClaims(access)
        var accountID = try Self.accountIDClaim(claims)
        if accountID == nil, let idToken = Self.nonempty(object["id_token"]) {
            accountID = try Self.accountIDClaim(Self.accessTokenClaims(idToken))
        }
        accountID = accountID ?? previous?.accountID
        let expiresAt: Date
        if let value = object["expires_in"] {
            guard let expires = Self.positiveNumber(value) else { throw OpenAISubscriptionAuthError.invalidResponse }
            expiresAt = now().addingTimeInterval(expires)
        } else if let expiration = Self.positiveNumber(claims["exp"]) {
            expiresAt = Date(timeIntervalSince1970: expiration)
        } else if access == previous?.accessToken, let previous {
            expiresAt = previous.expiresAt
        } else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        let tokens = try Self.sessionTokens(StoredTokens(
            accessToken: access, refreshToken: refresh, expiresAt: expiresAt, accountID: accountID
        ))
        guard tokens.stored.expiresAt > now() else { throw OpenAISubscriptionAuthError.invalidResponse }
        return tokens
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = request
        if request.timeoutInterval > 30 { request.timeoutInterval = 30 }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let result = try await transport(request)
            try Task.checkCancellation()
            // Real transport rejects redirects; also reject unexpected final origins in injected sessions.
            guard result.1.url?.scheme == "https", result.1.url?.host == "auth.openai.com",
                  result.0.count <= 1_048_576 else { throw OpenAISubscriptionAuthError.invalidResponse }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? OpenAISubscriptionAuthError { throw error }
            // Underlying errors/response bodies may contain secrets; never surface them.
            throw OpenAISubscriptionAuthError.network
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        return object
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func errorCode(_ data: Data) -> String? {
        guard let object = try? jsonObject(data) else { return nil }
        return (object["error"] as? String) ?? (object["error"] as? [String: Any])?["code"] as? String
    }

    private static func positiveNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }

    private static func accessTokenClaims(_ accessToken: String) throws -> [String: Any] {
        guard accessToken.utf8.count <= 65_536,
              !accessToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        let pieces = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty }) else { throw OpenAISubscriptionAuthError.invalidResponse }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { throw OpenAISubscriptionAuthError.invalidResponse }
        return try jsonObject(data)
    }

    private static func sessionTokens(_ stored: StoredTokens) throws -> SessionTokens {
        guard !stored.refreshToken.isEmpty, stored.expiresAt.timeIntervalSince1970.isFinite else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        let claims = try accessTokenClaims(stored.accessToken)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let claimedAccount = try accountIDClaim(claims)
        guard let accountID = claimedAccount ?? headerMetadata(stored.accountID),
              stored.accountID == nil || stored.accountID == accountID else {
            throw OpenAISubscriptionAuthError.invalidResponse
        }
        // JWT claims are unverified routing metadata, never proof of identity or entitlement.
        let residency = headerMetadata((auth["chatgpt_data_residency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? headerMetadata((auth["chatgpt_compute_residency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let expiry = positiveNumber(claims["exp"]).map { min(stored.expiresAt, Date(timeIntervalSince1970: $0)) } ?? stored.expiresAt
        let normalized = StoredTokens(
            accessToken: stored.accessToken, refreshToken: stored.refreshToken, expiresAt: expiry, accountID: accountID
        )
        return SessionTokens(stored: normalized, credential: OpenAISubscriptionCredential(
            accessToken: stored.accessToken, accountID: accountID, residency: residency
        ))
    }

    private static func accountIDClaim(_ claims: [String: Any]) throws -> String? {
        guard let value = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] else { return nil }
        guard let accountID = headerMetadata(value) else { throw OpenAISubscriptionAuthError.invalidResponse }
        return accountID
    }

    private static func headerMetadata(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return value
    }
}
