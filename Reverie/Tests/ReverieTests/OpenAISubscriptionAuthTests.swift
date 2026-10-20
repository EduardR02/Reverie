import XCTest
@testable import Reverie

@MainActor
final class OpenAISubscriptionAuthTests: XCTestCase {
    func testBrowserApprovalExchangesAuthorizationCodeWithPKCEAndStoresSubscriptionSession() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let openedURL = SubscriptionTestValue<URL>()
        let access = try Self.jwt(account: "account-123", residency: "eu")
        let http = SubscriptionHTTPStub(steps: [
            try .token(access, refresh: "refresh-one", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock)

        try await auth.signIn(openURL: { await openedURL.set($0) })
        let browserURL = await openedURL.value
        XCTAssertNotNil(browserURL, "Sign-in must automatically open the browser")
        let credential = try await auth.credential()
        XCTAssertEqual(credential.accountID, "account-123")
        XCTAssertEqual(credential.residency, "eu")
        XCTAssertEqual(store.saveCount, 1)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let exchange = try Self.form(request)
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["code"], "auth+code")
        XCTAssertEqual(exchange["code_verifier"], "proof+verifier")
        XCTAssertEqual(exchange["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertNil(exchange["refresh_token"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let persisted = try XCTUnwrap(String(data: XCTUnwrap(store.data), encoding: .utf8))
        for secret in ["auth+code", "proof+verifier"] {
            XCTAssertFalse(persisted.contains(secret))
        }
    }

    func testConcurrentRefreshIsSingleFlightAndPersistsRotatedRefreshToken() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let access = try Self.jwt(account: "account-123")
        let http = SubscriptionHTTPStub(steps: [
            try .token(access, refresh: "rotated+refresh/=", expires: 3_600, started: started, release: release),
            try .token(access, refresh: "next-refresh", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock)
        let first = Task { try await auth.credential() }
        await started.wait()
        let others = (0..<12).map { _ in Task { try await auth.credential() } }
        await release.open()
        _ = try await first.value
        for task in others {
            let credential = try await task.value
            XCTAssertEqual(credential.accountID, "account-123")
        }
        let initialRequests = await http.requests
        XCTAssertEqual(initialRequests.count, 1)
        XCTAssertEqual(store.saveCount, 1)
        let stored = try JSONDecoder().decode(OpenAISubscriptionAuth.StoredTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(stored.refreshToken, "rotated+refresh/=")

        // A new actor must pick up the rotated token from storage, not the old in-memory token.
        clock.advance(3_550)
        let reopened = Self.auth(store, http, clock)
        _ = try await reopened.credential()
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try Self.form(requests[1])["refresh_token"], "rotated+refresh/=")
    }

    func testLogoutInvalidatesRefreshEvenWhenTransportIgnoresCancellation() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "new-refresh", expires: 3_600, started: started, release: release)
        ])
        let auth = Self.auth(store, http, clock)
        let refreshing = Task { try await auth.credential() }
        await started.wait()
        try await auth.signOut()
        await release.open()
        await Self.expectCancellation { _ = try await refreshing.value }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testLogoutDuringTokenExchangeCannotRestoreSignedOutSession() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "new-refresh", expires: 3_600, started: started, release: release)
        ])
        let auth = Self.auth(store, http, clock)
        let login = Task { try await auth.signIn(openURL: { _ in }) }
        await started.wait()
        try await auth.signOut()
        await release.open()
        await Self.expectCancellation { try await login.value }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
        await Self.expect(.notConnected) { _ = try await auth.credential() }
    }

    func testCancellingBeforeBrowserApprovalPreventsExchangeAndAllowsFreshAttempt() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "fresh-refresh", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock, browserAuthorize: Self.approval(started: started, release: release))
        let login = Task { try await auth.signIn(openURL: { _ in }) }
        await started.wait()
        login.cancel()
        await release.open()
        await Self.expectCancellation { try await login.value }
        XCTAssertNil(store.data)
        let cancelledRequests = await http.requests
        XCTAssertTrue(cancelledRequests.isEmpty)
        try await auth.signIn(openURL: { _ in })
        let credential = try await auth.credential()
        XCTAssertEqual(credential.accountID, "account-123")
        XCTAssertEqual(store.saveCount, 1)
    }

    func testCancelledCredentialWaiterDoesNotCancelSharedRefresh() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "rotated", expires: 3_600, started: started, release: release)
        ])
        let auth = Self.auth(store, http, clock)
        let cancelled = Task { try await auth.credential() }
        await started.wait()
        let remaining = Task { try await auth.credential() }
        cancelled.cancel()
        await release.open()
        await Self.expectCancellation { _ = try await cancelled.value }
        let credential = try await remaining.value
        XCTAssertEqual(credential.accountID, "account-123")
        XCTAssertEqual(store.saveCount, 1)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFailedRotationStorageDisablesAccessAndDeletesObsoleteRefreshToken() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        store.failSave = true
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "rotated", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.credentialStorage) { _ = try await auth.credential() }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testFailedLoginStorageDoesNotReportConnected() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        store.failSave = true
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "new", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.credentialStorage) { try await auth.signIn(openURL: { _ in }) }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        XCTAssertNil(store.data)
    }

    func testFailedKeychainDeletionStillInvalidatesActorAndCanBeRetried() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        store.failDelete = true
        let auth = Self.auth(store, SubscriptionHTTPStub(steps: []), clock)
        await Self.expect(.credentialStorage) { try await auth.signOut() }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        XCTAssertNotNil(store.data)
        store.failDelete = false
        try await auth.signOut()
        XCTAssertNil(store.data)
    }

    func testFailedRotationAndFailedCleanupCannotReuseObsoleteStoredToken() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        store.failSave = true
        store.failDelete = true
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "rotated", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.credentialStorage) { _ = try await auth.credential() }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        // A storage failure is reported, never hidden by an in-memory-only session.
        let obsolete = try JSONDecoder().decode(OpenAISubscriptionAuth.StoredTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(obsolete.refreshToken, "old-refresh")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStorageReadFailureDoesNotAttemptNetworkOrFallback() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        store.failRead = true
        let http = SubscriptionHTTPStub(steps: [])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.credentialStorage) { _ = try await auth.credential() }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRevokedRefreshDeletesSessionWithoutFallingBack() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let http = SubscriptionHTTPStub(steps: [try .json(["error": "invalid_grant", "message": "secret-server-detail"], status: 400)])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.signInRequired) { _ = try await auth.credential() }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        XCTAssertNil(store.data)
        XCTAssertFalse(OpenAISubscriptionAuthError.signInRequired.localizedDescription.contains("secret-server-detail"))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLogoutBeforeBrowserApprovalRejectsLateCallbackWithoutTokenExchange() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [])
        let auth = Self.auth(store, http, clock, browserAuthorize: Self.approval(started: started, release: release))
        let login = Task { try await auth.signIn(openURL: { _ in }) }
        await started.wait()
        try await auth.signOut()
        await release.open()
        await Self.expectCancellation { try await login.value }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        await Self.expect(.notConnected) { _ = try await auth.credential() }
    }

    func testResidencyRoutingTrimsClaimsAndUsesComputeFallback() async throws {
        for residency in [" eu ", ""] {
            let clock = SubscriptionTestClock()
            let store = SubscriptionTestStore()
            let access = try Self.jwt(account: "account-123", residency: residency, computeResidency: " eu ")
            let http = SubscriptionHTTPStub(steps: [
                try .token(access, refresh: "fresh", expires: 3_600)
            ])
            let auth = Self.auth(store, http, clock)
            try await auth.signIn(openURL: { _ in })
            let credential = try await auth.credential()
            XCTAssertEqual(credential.residency, "eu")
        }
    }

    func testMissingOrUnsafeAccountClaimIsRejectedBeforePersistence() async throws {
        for account in [nil, "account\r\nInjected: value"] as [String?] {
            let clock = SubscriptionTestClock()
            let store = SubscriptionTestStore()
            let http = SubscriptionHTTPStub(steps: [
                try .token(Self.jwt(account: account), refresh: "new", expires: 3_600)
            ])
            let auth = Self.auth(store, http, clock)
            await Self.expect(.invalidResponse) { try await auth.signIn(openURL: { _ in }) }
            XCTAssertNil(store.data)
        }
    }

    func testRedirectResponseIsNotTreatedAsSuccessfulSignIn() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let http = SubscriptionHTTPStub(steps: [try .json([:], status: 302)])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.requestFailed(302)) { try await auth.signIn(openURL: { _ in }) }
        XCTAssertNil(store.data)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRefreshAcceptsJWTExpiryAndRetainsUnrotatedRefreshToken() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let access = try Self.jwt(account: "account-123", expiration: clock.now.addingTimeInterval(3_600))
        let http = SubscriptionHTTPStub(steps: [try .json(["access_token": access])])
        let auth = Self.auth(store, http, clock)
        let credential = try await auth.credential()
        XCTAssertEqual(credential.accessToken, access)
        let stored = try JSONDecoder().decode(OpenAISubscriptionAuth.StoredTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(stored.refreshToken, "old-refresh")
        XCTAssertEqual(stored.expiresAt, clock.now.addingTimeInterval(3_600))
        let requests = await http.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(try Self.form(XCTUnwrap(requests.first))["refresh_token"], "old-refresh")
    }

    func testJWTExpiryCannotBeExtendedByPersistedOrReportedLifetime() async throws {
        let clock = SubscriptionTestClock()
        let old = OpenAISubscriptionAuth.StoredTokens(
            accessToken: try Self.jwt(account: "account-123", expiration: clock.now.addingTimeInterval(-1)),
            refreshToken: "old-refresh", expiresAt: clock.now.addingTimeInterval(20_000)
        )
        let store = SubscriptionTestStore(data: try JSONEncoder().encode(old))
        let access = try Self.jwt(account: "account-123", expiration: clock.now.addingTimeInterval(120))
        let http = SubscriptionHTTPStub(steps: [try .token(access, refresh: "rotated", expires: 20_000)])
        let auth = Self.auth(store, http, clock)
        let credential = try await auth.credential()
        XCTAssertEqual(credential.accessToken, access)
        let stored = try JSONDecoder().decode(OpenAISubscriptionAuth.StoredTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(stored.expiresAt, clock.now.addingTimeInterval(120))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testConcurrentRejectedRequestsRefreshOnceAndReuseRotatedToken() async throws {
        let clock = SubscriptionTestClock()
        let rejected = try Self.jwt(account: "account-123", expiration: clock.now.addingTimeInterval(3_600))
        let rotated = try Self.jwt(account: "account-123", expiration: clock.now.addingTimeInterval(7_200))
        let stored = OpenAISubscriptionAuth.StoredTokens(accessToken: rejected, refreshToken: "old-refresh", expiresAt: clock.now.addingTimeInterval(3_600))
        let store = SubscriptionTestStore(data: try JSONEncoder().encode(stored))
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [try .token(rotated, refresh: "rotated-refresh", expires: 7_200, started: started, release: release)])
        let auth = Self.auth(store, http, clock)
        let first = Task { try await auth.refreshCredential(rejectedAccessToken: rejected) }
        await started.wait()
        let others = (0..<8).map { _ in Task { try await auth.refreshCredential(rejectedAccessToken: rejected) } }
        await release.open()
        let firstCredential = try await first.value
        XCTAssertEqual(firstCredential.accessToken, rotated)
        for task in others {
            let credential = try await task.value
            XCTAssertEqual(credential.accessToken, rotated)
        }
        let reused = try await auth.refreshCredential(rejectedAccessToken: rejected)
        XCTAssertEqual(reused.accessToken, rotated)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testRejectedRequestCannotBorrowAnotherAccountsCurrentSession() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(account: "new-account", expiration: clock.now.addingTimeInterval(3_600))
        let stored = OpenAISubscriptionAuth.StoredTokens(accessToken: access, refreshToken: "current-refresh", expiresAt: clock.now.addingTimeInterval(3_600))
        let store = SubscriptionTestStore(data: try JSONEncoder().encode(stored))
        let http = SubscriptionHTTPStub(steps: [])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.signInRequired) {
            _ = try await auth.refreshCredential(rejectedAccessToken: Self.jwt(account: "old-account"))
        }
        let current = try await auth.credential()
        XCTAssertEqual(current.accountID, "new-account")
        XCTAssertNotNil(store.data)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRefreshCannotSilentlyChangeSubscriptionAccount() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let http = SubscriptionHTTPStub(steps: [try .token(Self.jwt(account: "different-account"), refresh: "different-refresh", expires: 3_600)])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.signInRequired) { _ = try await auth.credential() }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
        await Self.expect(.notConnected) { _ = try await auth.credential() }
    }

    func testExpiredReusedAndRevokedRefreshCodesDeleteSessionEvenOnHTTP400() async throws {
        for code in ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"] {
            let clock = SubscriptionTestClock()
            let store = try Self.expiredStore(clock)
            let http = SubscriptionHTTPStub(steps: [try .json(["error": ["code": code, "message": "credential-secret"]], status: 400)])
            let auth = Self.auth(store, http, clock)
            await Self.expect(.signInRequired) { _ = try await auth.credential() }
            await Self.expect(.notConnected) { _ = try await auth.credential() }
            XCTAssertNil(store.data)
        }
    }

    func testTransientRefreshFailurePreservesSessionForAnotherAttempt() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let http = SubscriptionHTTPStub(steps: [
            try .json(["message": "credential-secret"], status: 503),
            try .token(Self.jwt(account: "account-123"), refresh: "rotated", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.requestFailed(503)) { _ = try await auth.credential() }
        XCTAssertNotNil(store.data)
        let credential = try await auth.credential()
        XCTAssertEqual(credential.accountID, "account-123")
        XCTAssertEqual(store.saveCount, 1)
    }

    func testCancelledWaiterReportsCancellationWhenSharedRefreshFails() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [try .json(["error": "invalid_grant"], status: 400, started: started, release: release)])
        let auth = Self.auth(store, http, clock)
        let cancelled = Task { try await auth.credential() }
        await started.wait()
        let remaining = Task { try await auth.credential() }
        cancelled.cancel()
        await release.open()
        await Self.expectCancellation { _ = try await cancelled.value }
        do {
            _ = try await remaining.value
            XCTFail("Revoked credentials must not be returned to another waiter")
        } catch {
            XCTAssertTrue([OpenAISubscriptionAuthError.signInRequired, .notConnected].contains(error as? OpenAISubscriptionAuthError))
        }
        XCTAssertNil(store.data)
    }

    func testCancellingDuringTokenExchangeCannotPersistLateResponse() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "late-refresh", expires: 3_600, started: started, release: release)
        ])
        let auth = Self.auth(store, http, clock)
        let login = Task { try await auth.signIn(openURL: { _ in }) }
        await started.wait()
        login.cancel()
        await auth.cancelSignIn()
        await release.open()
        await Self.expectCancellation { try await login.value }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
        await Self.expect(.notConnected) { _ = try await auth.credential() }
    }

    func testTransportErrorsAndUnexpectedOriginsNeverExposeSecrets() async throws {
        let clock = SubscriptionTestClock()
        let cases: [OpenAISubscriptionAuth.Transport] = [
            { _ in throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "credential-secret"]) },
            { _ in (Data(), HTTPURLResponse(url: URL(string: "https://attacker.invalid/?credential-secret")!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        ]
        for (index, transport) in cases.enumerated() {
            let store = SubscriptionTestStore()
            let auth = OpenAISubscriptionAuth(store: store, transport: transport, now: { clock.now }, browserAuthorize: Self.approval())
            await Self.expect(index == 0 ? .network : .invalidResponse) { try await auth.signIn(openURL: { _ in }) }
            XCTAssertNil(store.data)
        }
    }

    func testSessionRevisionSurvivesMissedNotificationsButNotOrdinaryTokenRotation() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let http = SubscriptionHTTPStub(steps: [try .token(Self.jwt(account: "account-123"), refresh: "rotated", expires: 3_600)])
        let auth = Self.auth(store, http, clock)
        let original = auth.sessionRevision
        _ = try await auth.credential()
        XCTAssertEqual(auth.sessionRevision, original)
        store.failDelete = true
        await Self.expect(.credentialStorage) { try await auth.signOut() }
        XCTAssertNotEqual(auth.sessionRevision, original)
        await Self.expect(.notConnected) { _ = try await auth.credential() }
    }

    func testCompletedLoginChangesSessionRevisionButCancelledLoginDoesNot() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [
            try .token(Self.jwt(account: "account-123"), refresh: "fresh", expires: 3_600)
        ])
        let auth = Self.auth(store, http, clock, browserAuthorize: Self.approval(started: started, release: release))
        let original = auth.sessionRevision
        let cancelled = Task { try await auth.signIn(openURL: { _ in }) }
        await started.wait()
        await auth.cancelSignIn()
        await release.open()
        await Self.expectCancellation { try await cancelled.value }
        XCTAssertEqual(auth.sessionRevision, original)
        try await auth.signIn(openURL: { _ in })
        XCTAssertNotEqual(auth.sessionRevision, original)
    }

    func testBrowserRejectionAndCallbackFailuresNeverExchangeOrSaveCredentials() async throws {
        for failure in [
            OpenAISubscriptionAuthError.accessDenied,
            .callbackUnavailable,
            .signInTimedOut,
            .browserUnavailable,
            .invalidResponse
        ] {
            let clock = SubscriptionTestClock()
            let store = SubscriptionTestStore()
            let http = SubscriptionHTTPStub(steps: [])
            let auth = Self.auth(store, http, clock, browserAuthorize: { _ in throw failure })
            await Self.expect(failure) { try await auth.signIn(openURL: { _ in }) }
            await Self.expect(.notConnected) { _ = try await auth.credential() }
            let requests = await http.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNil(store.data)
            XCTAssertEqual(store.saveCount, 0)
        }
    }

    func testBrowserOpeningFailureRedactsAuthorizationURLAndSecrets() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let http = SubscriptionHTTPStub(steps: [])
        let auth = Self.auth(store, http, clock)
        do {
            try await auth.signIn(openURL: { _ in
                throw NSError(domain: "Browser", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "https://auth.openai.com/oauth/authorize?state=secret-state&code_challenge=secret-proof"
                ])
            })
            XCTFail("A failed browser launch must fail sign-in")
        } catch {
            XCTAssertEqual(error as? OpenAISubscriptionAuthError, .browserUnavailable)
            for secret in ["https://", "secret-state", "secret-proof", "code_challenge"] {
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(store.data)
    }

    func testBrowserCancellationDoesNotBecomeAnErrorOrExchangeTokens() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let http = SubscriptionHTTPStub(steps: [])
        let auth = Self.auth(store, http, clock, browserAuthorize: { _ in throw CancellationError() })
        await Self.expectCancellation { try await auth.signIn(openURL: { _ in }) }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(store.data)
        XCTAssertEqual(auth.sessionRevision, 0)
    }

    func testBrowserApprovalInProgressPreventsSecondSignInAndCredentialUse() async throws {
        let clock = SubscriptionTestClock()
        let store = try Self.expiredStore(clock)
        let started = SubscriptionTestGate()
        let release = SubscriptionTestGate()
        let http = SubscriptionHTTPStub(steps: [])
        let auth = Self.auth(store, http, clock, browserAuthorize: Self.approval(started: started, release: release))
        let login = Task { try await auth.signIn(openURL: { _ in }) }
        await started.wait()
        await Self.expect(.signInInProgress) { try await auth.signIn(openURL: { _ in }) }
        await Self.expect(.signInInProgress) { _ = try await auth.credential() }
        await auth.cancelSignIn()
        await release.open()
        await Self.expectCancellation { try await login.value }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testIDTokenAccountPersistsWithoutIDTokenAndSurvivesRefreshWithoutAccountClaims() async throws {
        let clock = SubscriptionTestClock()
        let store = SubscriptionTestStore()
        let initial = try Self.jwt(account: nil, expiration: clock.now.addingTimeInterval(3_600))
        let renewed = try Self.jwt(account: nil, expiration: clock.now.addingTimeInterval(7_200))
        let idToken = try Self.jwt(account: "id-token-account")
        let http = SubscriptionHTTPStub(steps: [
            try .json(["access_token": initial, "refresh_token": "initial-refresh", "expires_in": 3_600, "id_token": idToken]),
            try .token(renewed, refresh: "rotated-refresh", expires: 7_200)
        ])
        let auth = Self.auth(store, http, clock)
        try await auth.signIn(openURL: { _ in })
        let connected = try await auth.credential()
        XCTAssertEqual(connected.accountID, "id-token-account")
        let stored = try JSONDecoder().decode(OpenAISubscriptionAuth.StoredTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(stored.accountID, "id-token-account")
        XCTAssertFalse(try XCTUnwrap(String(data: XCTUnwrap(store.data), encoding: .utf8)).contains(idToken))

        let reopened = Self.auth(store, http, clock)
        let refreshed = try await reopened.refreshCredential(rejectedAccessToken: initial)
        XCTAssertEqual(refreshed.accountID, "id-token-account")
        XCTAssertEqual(refreshed.accessToken, renewed)
        let reused = try await reopened.refreshCredential(rejectedAccessToken: initial)
        XCTAssertEqual(reused.accessToken, renewed)
        let persisted = try JSONDecoder().decode(OpenAISubscriptionAuth.StoredTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(persisted.accountID, "id-token-account")
        XCTAssertEqual(persisted.refreshToken, "rotated-refresh")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testRefreshIDTokenCannotSilentlyChangeSubscriptionAccount() async throws {
        let clock = SubscriptionTestClock()
        let access = try Self.jwt(account: nil)
        let stored = OpenAISubscriptionAuth.StoredTokens(
            accessToken: access, refreshToken: "old-refresh", expiresAt: clock.now.addingTimeInterval(-1),
            accountID: "original-account"
        )
        let store = SubscriptionTestStore(data: try JSONEncoder().encode(stored))
        let http = SubscriptionHTTPStub(steps: [
            try .json([
                "access_token": access, "refresh_token": "different-refresh", "expires_in": 3_600,
                "id_token": Self.jwt(account: "different-account")
            ])
        ])
        let auth = Self.auth(store, http, clock)
        await Self.expect(.signInRequired) { _ = try await auth.credential() }
        await Self.expect(.notConnected) { _ = try await auth.credential() }
        XCTAssertNil(store.data)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testClaimlessRejectedTokenCannotBorrowAnotherAccountsNewLogin() async throws {
        let clock = SubscriptionTestClock()
        let old = try Self.jwt(account: nil, expiration: clock.now.addingTimeInterval(3_600))
        let current = try Self.jwt(account: nil, expiration: clock.now.addingTimeInterval(7_200))
        let store = SubscriptionTestStore()
        let http = SubscriptionHTTPStub(steps: [
            try .json([
                "access_token": old, "refresh_token": "old-refresh", "expires_in": 3_600,
                "id_token": Self.jwt(account: "old-account")
            ]),
            try .json([
                "access_token": current, "refresh_token": "current-refresh", "expires_in": 7_200,
                "id_token": Self.jwt(account: "new-account")
            ])
        ])
        let auth = Self.auth(store, http, clock)
        try await auth.signIn(openURL: { _ in })
        try await auth.signIn(openURL: { _ in })
        await Self.expect(.signInRequired) { _ = try await auth.refreshCredential(rejectedAccessToken: old) }
        let credential = try await auth.credential()
        XCTAssertEqual(credential.accountID, "new-account")
        XCTAssertEqual(credential.accessToken, current)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    private static func auth(
        _ store: SubscriptionTestStore,
        _ http: SubscriptionHTTPStub,
        _ clock: SubscriptionTestClock,
        browserAuthorize: OpenAISubscriptionAuth.BrowserAuthorize? = nil
    ) -> OpenAISubscriptionAuth {
        OpenAISubscriptionAuth(
            store: store,
            transport: { try await http.send($0) },
            now: { clock.now },
            browserAuthorize: browserAuthorize ?? approval()
        )
    }

    private static func approval(
        started: SubscriptionTestGate? = nil,
        release: SubscriptionTestGate? = nil
    ) -> OpenAISubscriptionAuth.BrowserAuthorize {
        { openURL in
            try await openURL(URL(string: "https://auth.openai.com/oauth/authorize?state=synthetic")!)
            await started?.open()
            // A late browser callback must not revive a cancelled or signed-out session.
            await release?.wait()
            return OpenAIBrowserAuthorization(code: "auth+code", verifier: "proof+verifier")
        }
    }

    private static func expiredStore(_ clock: SubscriptionTestClock) throws -> SubscriptionTestStore {
        let tokens = OpenAISubscriptionAuth.StoredTokens(accessToken: try jwt(account: "account-123"), refreshToken: "old-refresh", expiresAt: clock.now.addingTimeInterval(-1))
        return SubscriptionTestStore(data: try JSONEncoder().encode(tokens))
    }

    private static func jwt(account: String?, residency: String? = nil, computeResidency: String? = nil, expiration: Date? = nil) throws -> String {
        var auth: [String: String] = [:]
        auth["chatgpt_account_id"] = account
        auth["chatgpt_data_residency"] = residency
        auth["chatgpt_compute_residency"] = computeResidency
        var claims: [String: Any] = ["https://api.openai.com/auth": auth]
        if let expiration { claims["exp"] = expiration.timeIntervalSince1970 }
        let payload = try JSONSerialization.data(withJSONObject: claims)
        return "eyJhbGciOiJub25lIn0.\(payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")).test-signature"
    }

    private static func form(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        let components = try XCTUnwrap(URLComponents(string: "https://test.invalid/?" + body))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func expect(_ expected: OpenAISubscriptionAuthError, operation: @MainActor () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected authentication failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OpenAISubscriptionAuthError, expected, file: file, line: line)
        }
    }

    private static func expectCancellation(operation: @MainActor () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }
}

final class SubscriptionTestStore: OpenAISubscriptionCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var saves = 0
    private var readFailure = false
    private var saveFailure = false
    private var deleteFailure = false

    init(data: Data? = nil) { bytes = data }
    var data: Data? { lock.withLock { bytes } }
    var saveCount: Int { lock.withLock { saves } }
    var failRead: Bool {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }
    var failSave: Bool {
        get { lock.withLock { saveFailure } }
        set { lock.withLock { saveFailure = newValue } }
    }
    var failDelete: Bool {
        get { lock.withLock { deleteFailure } }
        set { lock.withLock { deleteFailure = newValue } }
    }
    func read() throws -> Data? {
        try lock.withLock {
            if readFailure { throw OpenAISubscriptionAuthError.credentialStorage }
            return bytes
        }
    }
    func save(_ data: Data) throws {
        try lock.withLock {
            if saveFailure { throw OpenAISubscriptionAuthError.credentialStorage }
            bytes = data
            saves += 1
        }
    }
    func delete() throws {
        try lock.withLock {
            if deleteFailure { throw OpenAISubscriptionAuthError.credentialStorage }
            bytes = nil
        }
    }
}

final class SubscriptionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 10_000)
    var now: Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

actor SubscriptionTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor SubscriptionTestValue<Value: Sendable> {
    var value: Value?
    func set(_ value: Value) { self.value = value }
}

actor SubscriptionHTTPStub {
    struct Step: Sendable {
        let status: Int
        let data: Data
        let started: SubscriptionTestGate?
        let release: SubscriptionTestGate?

        static func json(_ object: [String: Any], status: Int = 200, started: SubscriptionTestGate? = nil, release: SubscriptionTestGate? = nil) throws -> Step {
            Step(status: status, data: try JSONSerialization.data(withJSONObject: object), started: started, release: release)
        }
        static func token(_ access: String, refresh: String, expires: Int, started: SubscriptionTestGate? = nil, release: SubscriptionTestGate? = nil) throws -> Step {
            try json(["access_token": access, "refresh_token": refresh, "expires_in": expires], started: started, release: release)
        }
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        await step.started?.open()
        // Deliberately ignore cancellation: tests must prove the actor rejects late responses.
        await step.release?.wait()
        return (step.data, HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: nil)!)
    }
}
