//
//  BrowserSsoTests.swift
//  networkTests
//
//  The browser sign-in contract of the direct-download build (BrowserSso):
//  the authorize urls Google and Apple receive, the state the api's callback
//  reads the platform from, the return parsing, and the two checks that
//  make a return usable (echoed state, token nonce) with the attempt store
//  that enforces them once and times stale attempts out.
//

import Foundation
import Testing
@testable import URnetwork

struct BrowserSsoTests {

    static let api = "https://api.bringyour.com"

    /// A token shaped like an identity token: unsigned, the server rejects it.
    static func identityToken(nonce: String?, issuer: String = "https://accounts.google.com") -> String {
        var payload: [String: Any] = ["iss": issuer, "sub": "simulated"]
        if let nonce {
            payload["nonce"] = nonce
        }
        let header = BrowserSso.base64UrlEncode(Data("{\"alg\":\"none\",\"typ\":\"JWT\"}".utf8))
        let body = BrowserSso.base64UrlEncode(try! JSONSerialization.data(withJSONObject: payload))
        return header + "." + body + "."
    }

    static func returnURL(_ provider: String, _ query: [(String, String)]) -> URL {
        URL(string: "urnetwork://oauth/\(provider)?" + BrowserSso.encodeQuery(query))!
    }

    // MARK: urls

    @Test func theGoogleAuthorizeUrlIsTheCodeFlowOnTheApiCallback() {
        let url = BrowserSso.authorizeURL(.google, apiUrl: Self.api + "/", state: "st/at+e", nonce: "n once")!
        #expect(url.absoluteString ==
            "https://accounts.google.com/o/oauth2/v2/auth"
            + "?client_id=338638865390-cg4m0t700mq9073smhn9do81mr640ig1.apps.googleusercontent.com"
            + "&redirect_uri=https%3A%2F%2Fapi.bringyour.com%2Fauth%2Fgoogle%2Fcallback"
            + "&response_type=code"
            + "&scope=openid%20email%20profile"
            + "&state=st%2Fat%2Be&nonce=n%20once"
            + "&prompt=select_account")
    }

    @Test func theAppleAuthorizeUrlPostsCodeAndIdTokenToTheApiCallback() {
        let url = BrowserSso.authorizeURL(.apple, apiUrl: Self.api, state: "s", nonce: "n")!
        #expect(url.absoluteString ==
            "https://appleid.apple.com/auth/authorize"
            + "?client_id=network.ur.service"
            + "&redirect_uri=https%3A%2F%2Fapi.bringyour.com%2Fauth%2Fapple%2Fcallback"
            + "&response_type=code%20id_token"
            + "&response_mode=form_post"
            + "&scope=name%20email"
            + "&state=s&nonce=n")
    }

    @Test func theCallbacksAreTheRedirectUrisToRegister() {
        // these exact strings go in Google Cloud (web client authorized
        // redirect URIs) and on the Apple Services ID (return URLs)
        #expect(BrowserSso.callbackURL(.google, apiUrl: "https://api.bringyour.com") == "https://api.bringyour.com/auth/google/callback")
        #expect(BrowserSso.callbackURL(.apple, apiUrl: "https://api.bringyour.com/") == "https://api.bringyour.com/auth/apple/callback")
        #expect(BrowserSso.callbackURL(.google, apiUrl: "https://api.ur.network///") == "https://api.ur.network/auth/google/callback")
    }

    @Test func noApiOriginNoUrl() {
        #expect(BrowserSso.authorizeURL(.google, apiUrl: "", state: "s", nonce: "n") == nil)
        #expect(BrowserSso.authorizeURL(.apple, apiUrl: "api.bringyour.com", state: "s", nonce: "n") == nil)
        #expect(BrowserSso.authorizeURL(.apple, apiUrl: Self.api, state: "", nonce: "n") == nil)
        #expect(BrowserSso.authorizeURL(.apple, apiUrl: Self.api, state: "s", nonce: "") == nil)
    }

    // MARK: state

    @Test func theStateIsTheServersBase64UrlJsonWithTheMacosPlatform() {
        // appleOAuthTestState("macos") in server/controller: the platform
        // claim is what oauthSchemes maps to urnetwork://
        #expect(BrowserSso.state(token: "abc123") == "eyJwbGF0Zm9ybSI6Im1hY29zIiwidG9rZW4iOiJhYmMxMjMifQ")
        #expect(BrowserSso.state(token: "abc123", platform: "linux") == "eyJwbGF0Zm9ybSI6ImxpbnV4IiwidG9rZW4iOiJhYmMxMjMifQ")
        #expect(BrowserSso.platform == "macos")
    }

    @Test func theStateRoundTrips() {
        let token = UUID().uuidString.lowercased()
        let claims = BrowserSso.stateClaims(BrowserSso.state(token: token))
        #expect(claims?.platform == "macos")
        #expect(claims?.token == token)
        // a quote in a token cannot break the object
        #expect(BrowserSso.stateClaims(BrowserSso.state(token: "a\"b\\c"))?.token == "a\"b\\c")
        // the padded and the standard alphabets decode too
        #expect(BrowserSso.stateClaims("eyJwbGF0Zm9ybSI6Im1hY29zIiwidG9rZW4iOiJhYmMxMjMifQ==")?.token == "abc123")
        #expect(BrowserSso.stateClaims("plainrandomstate") == nil)
        #expect(BrowserSso.stateClaims("") == nil)
    }

    @Test func everyAttemptHasAFreshStateAndNonce() {
        let store = BrowserSsoAttemptStore()
        let first = store.begin(.google)
        let second = store.begin(.google)
        #expect(first.state != second.state)
        #expect(first.nonce != second.nonce)
        #expect(BrowserSso.stateClaims(first.state)?.platform == "macos")
        #expect(BrowserSso.stateClaims(first.state)?.token != BrowserSso.stateClaims(second.state)?.token)
    }

    // MARK: the return

    @Test func theReturnIsParsed() {
        let token = Self.identityToken(nonce: "n1")
        let r = BrowserSso.parseReturn(Self.returnURL("google", [("state", "s1"), ("id_token", token)]))
        #expect(r == BrowserSso.Return(provider: .google, state: "s1", idToken: token, error: ""))

        // the server encodes the query with Go's url.Values (a space is "+")
        let e = BrowserSso.parseReturn(URL(string: "urnetwork://oauth/apple?error=Apple+did+not+return+an+identity+token.&state=s2")!)
        #expect(e == BrowserSso.Return(provider: .apple, state: "s2", idToken: "", error: "Apple did not return an identity token."))

        // Apple's first-authorization extras ride along unread
        let a = BrowserSso.parseReturn(URL(string: "urnetwork://oauth/apple?code=c0de&id_token=h.p.s&state=s3&user=%7B%22email%22%3A%22ada%40example.com%22%7D")!)
        #expect(a == BrowserSso.Return(provider: .apple, state: "s3", idToken: "h.p.s", error: ""))
    }

    @Test func otherLinksAreNotReturns() {
        #expect(BrowserSso.parseReturn(URL(string: "urnetwork://oauth/github?state=s")!) == nil)
        #expect(BrowserSso.parseReturn(URL(string: "urnetwork://oauth")!) == nil)
        #expect(BrowserSso.parseReturn(URL(string: "urnetwork://pay/done")!) == nil)
        #expect(BrowserSso.parseReturn(URL(string: "urnetwork://onboarding/connect")!) == nil)
        #expect(BrowserSso.parseReturn(URL(string: "urnetwork://widgets/connect")!) == nil)
        #expect(BrowserSso.parseReturn(URL(string: "https://api.bringyour.com/oauth/google?state=s")!) == nil)
        #expect(BrowserSso.parseReturn(URL(string: "com.googleusercontent.apps.x:/oauth2redirect")!) == nil)
        // the other routers keep theirs
        #expect(BillingDeepLink(url: Self.returnURL("google", [("state", "s")])) == nil)
        #expect(OnboardingDestination(url: Self.returnURL("apple", [("state", "s")])) == nil)
    }

    @Test func theNonceClaimIsReadNeverVerified() {
        #expect(BrowserSso.jwtClaim(Self.identityToken(nonce: "n1"), "nonce") == "n1")
        #expect(BrowserSso.jwtClaim(Self.identityToken(nonce: nil), "nonce") == nil)
        #expect(BrowserSso.jwtClaim("not.a.jwt", "nonce") == nil)
        #expect(BrowserSso.jwtClaim("", "nonce") == nil)
    }

    // MARK: the checks

    @Test func aReturnForTheAttemptInFlightSignsIn() {
        let store = BrowserSsoAttemptStore()
        let attempt = store.begin(.google)
        let token = Self.identityToken(nonce: attempt.nonce)
        let r = BrowserSso.parseReturn(Self.returnURL("google", [("state", attempt.state), ("id_token", token)]))!
        #expect(store.take(r) == .success(token))
        // the attempt is over
        #expect(store.pending == nil)
    }

    @Test func aReplayIsRejected() {
        let store = BrowserSsoAttemptStore()
        let attempt = store.begin(.apple)
        let token = Self.identityToken(nonce: attempt.nonce, issuer: "https://appleid.apple.com")
        let r = BrowserSso.parseReturn(Self.returnURL("apple", [("state", attempt.state), ("id_token", token)]))!
        #expect(store.take(r) == .success(token))
        // the same return again: nothing is waiting for it
        #expect(store.take(r) == .failure(.noAttempt))
        #expect(BrowserSso.Failure.noAttempt.isStray)

        // a return of a previous attempt, after a new one started, is a
        // replay too and leaves the new attempt untouched
        let next = store.begin(.apple)
        #expect(store.take(r) == .failure(.unexpectedReturn))
        #expect(BrowserSso.Failure.unexpectedReturn.isStray)
        #expect(store.pending == next)
    }

    @Test func aStrayReturnLeavesTheAttemptInFlight() {
        let store = BrowserSsoAttemptStore()
        let attempt = store.begin(.google)
        let stray = BrowserSso.parseReturn(Self.returnURL("google", [("state", "someone-elses"), ("id_token", Self.identityToken(nonce: attempt.nonce))]))!
        #expect(store.take(stray) == .failure(.unexpectedReturn))
        let empty = BrowserSso.parseReturn(Self.returnURL("google", [("id_token", Self.identityToken(nonce: attempt.nonce))]))!
        #expect(store.take(empty) == .failure(.unexpectedReturn))
        #expect(store.pending == attempt)
    }

    @Test func aTokenMintedForAnotherNonceIsRejected() {
        let store = BrowserSsoAttemptStore()
        let attempt = store.begin(.google)
        let r = BrowserSso.parseReturn(Self.returnURL("google", [("state", attempt.state), ("id_token", Self.identityToken(nonce: "another"))]))!
        #expect(store.take(r) == .failure(.nonceMismatch))
        #expect(!BrowserSso.Failure.nonceMismatch.isStray)
        // the echoed state ended the attempt either way: no second try
        #expect(store.pending == nil)

        let again = store.begin(.google)
        let noNonce = BrowserSso.parseReturn(Self.returnURL("google", [("state", again.state), ("id_token", Self.identityToken(nonce: nil))]))!
        #expect(store.take(noNonce) == .failure(.nonceMismatch))
    }

    @Test func theProvidersErrorAndAMissingTokenFailTheAttempt() {
        let store = BrowserSsoAttemptStore()
        var attempt = store.begin(.apple)
        let denied = BrowserSso.parseReturn(Self.returnURL("apple", [("state", attempt.state), ("error", "user_cancelled_authorize")]))!
        #expect(store.take(denied) == .failure(.provider("user_cancelled_authorize")))
        #expect(BrowserSso.Failure.provider("user_cancelled_authorize").userMessage == "user_cancelled_authorize")
        #expect(store.pending == nil)

        attempt = store.begin(.apple)
        let empty = BrowserSso.parseReturn(Self.returnURL("apple", [("state", attempt.state)]))!
        #expect(store.take(empty) == .failure(.noToken))

        // the state of a Google attempt echoed on the Apple path
        attempt = store.begin(.google)
        let crossed = BrowserSso.parseReturn(Self.returnURL("apple", [("state", attempt.state), ("id_token", Self.identityToken(nonce: attempt.nonce))]))!
        #expect(store.take(crossed) == .failure(.providerMismatch))
    }

    @Test func aStaleAttemptTimesOut() {
        let store = BrowserSsoAttemptStore(timeout: 60)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let attempt = store.begin(.google, now: t0)
        let token = Self.identityToken(nonce: attempt.nonce)
        let r = BrowserSso.parseReturn(Self.returnURL("google", [("state", attempt.state), ("id_token", token)]))!

        // within the window the attempt is live
        #expect(store.isPending(attempt, now: t0 + 59))
        #expect(store.current(now: t0 + 60) == attempt)

        // past it the return is late, and the attempt is gone
        #expect(store.take(r, now: t0 + 61) == .failure(.expired))
        #expect(!BrowserSso.Failure.expired.isStray)
        #expect(store.pending == nil)
        #expect(store.take(r, now: t0 + 61) == .failure(.noAttempt))

        // asking about a stale attempt drops it too
        let second = store.begin(.apple, now: t0)
        #expect(!store.isPending(second, now: t0 + 61))
        #expect(store.current(now: t0 + 61) == nil)
        #expect(store.pending == nil)

        #expect(BrowserSso.attemptTimeout == 5 * 60)
        #expect(BrowserSsoAttemptStore().timeout == BrowserSso.attemptTimeout)
    }

    @Test func cancelDropsTheAttempt() {
        let store = BrowserSsoAttemptStore()
        let attempt = store.begin(.google)
        store.cancel()
        #expect(store.pending == nil)
        let r = BrowserSso.parseReturn(Self.returnURL("google", [("state", attempt.state), ("id_token", Self.identityToken(nonce: attempt.nonce))]))!
        #expect(store.take(r) == .failure(.noAttempt))
    }

    // MARK: the login screen's view model

    @Test @MainActor func theViewModelHandsTheIdentityTokenToTheNativeLoginPath() {
        let viewModel = LoginInitialView.ViewModel(urApiService: MockUrApiService())
        var timedOut = false
        let url = viewModel.startBrowserSso(.apple, apiUrl: Self.api, onTimeout: { timedOut = true })
        #expect(url?.host == "appleid.apple.com")
        let attempt = viewModel.browserSsoAttempts.pending!
        #expect(attempt.provider == .apple)
        #expect(url?.absoluteString.contains("state=" + BrowserSso.escape(attempt.state)) == true)
        #expect(url?.absoluteString.contains("nonce=" + attempt.nonce) == true)
        #expect(viewModel.browserSsoTimeoutTask != nil)

        let token = Self.identityToken(nonce: attempt.nonce, issuer: "https://appleid.apple.com")
        let r = BrowserSso.parseReturn(Self.returnURL("apple", [("state", attempt.state), ("id_token", token)]))!
        switch viewModel.createBrowserSsoAuthLoginArgs(r) {
        case .success(let args):
            // the same auth_jwt + auth_jwt_type the native ASAuthorization
            // flow builds (createAppleAuthLoginArgs)
            #expect(args.authJwt == token)
            #expect(args.authJwtType == "apple")
        case .failure(let failure):
            Issue.record("rejected: \(failure)")
        }
        // the attempt is over, with its timeout
        #expect(viewModel.browserSsoAttempts.pending == nil)
        #expect(viewModel.browserSsoTimeoutTask == nil)
        #expect(!timedOut)
        // and a replay is rejected
        #expect(viewModel.createBrowserSsoAuthLoginArgs(r) == .failure(.noAttempt))
    }

    @Test @MainActor func theViewModelRejectsTheWrongNonceAndKeepsAStrayReturnFromEndingTheAttempt() {
        let viewModel = LoginInitialView.ViewModel(urApiService: MockUrApiService())
        _ = viewModel.startBrowserSso(.google, apiUrl: Self.api, onTimeout: {})
        let attempt = viewModel.browserSsoAttempts.pending!

        let stray = BrowserSso.parseReturn(Self.returnURL("google", [("state", "other"), ("id_token", Self.identityToken(nonce: attempt.nonce))]))!
        #expect(viewModel.createBrowserSsoAuthLoginArgs(stray) == .failure(.unexpectedReturn))
        #expect(viewModel.browserSsoAttempts.pending == attempt)
        #expect(viewModel.browserSsoTimeoutTask != nil)

        let wrongNonce = BrowserSso.parseReturn(Self.returnURL("google", [("state", attempt.state), ("id_token", Self.identityToken(nonce: "x"))]))!
        #expect(viewModel.createBrowserSsoAuthLoginArgs(wrongNonce) == .failure(.nonceMismatch))
        #expect(viewModel.browserSsoAttempts.pending == nil)
        #expect(viewModel.browserSsoTimeoutTask == nil)
    }

    @Test @MainActor func theViewModelNeedsAnApiOriginAndCanCancel() {
        let viewModel = LoginInitialView.ViewModel(urApiService: MockUrApiService())
        #expect(viewModel.startBrowserSso(.google, apiUrl: "", onTimeout: {}) == nil)
        #expect(viewModel.browserSsoAttempts.pending == nil)

        _ = viewModel.startBrowserSso(.google, apiUrl: Self.api, onTimeout: {})
        #expect(viewModel.browserSsoAttempts.pending != nil)
        viewModel.cancelBrowserSso()
        #expect(viewModel.browserSsoAttempts.pending == nil)
        #expect(viewModel.browserSsoTimeoutTask == nil)

        #expect(BrowserSsoProvider.google.loginAction == .google)
        #expect(BrowserSsoProvider.apple.loginAction == .apple)
    }

    @Test @MainActor func theRouterHoldsTheReturnUntilItIsTaken() {
        let router = DeepLinkRouter()
        #expect(router.consumeBrowserSso() == nil)
        let r = BrowserSso.parseReturn(Self.returnURL("google", [("state", "s"), ("id_token", "h.p.s")]))!
        router.open(r)
        #expect(router.pendingBrowserSso == r)
        #expect(router.consumeBrowserSso() == r)
        #expect(router.pendingBrowserSso == nil)
        #expect(router.consumeBrowserSso() == nil)
    }

    // MARK: who offers it

    @Test func theBrowserFlowStandsInForTheDirectFamilyOnly() {
        #expect(!BrowserSsoConfiguration.isAvailable(for: TunnelProviderIdentity.appStore))
        #if os(macOS)
        #expect(BrowserSsoConfiguration.isAvailable(for: TunnelProviderIdentity.direct))
        #else
        #expect(!BrowserSsoConfiguration.isAvailable(for: TunnelProviderIdentity.direct))
        #endif
        #expect(Config.isBrowserSignInAvailable == BrowserSsoConfiguration.isAvailable(for: TunnelProviderIdentity.flavor))
        // never alongside a native flow
        #if DIRECT_DOWNLOAD
        #expect(!Config.isAppleSignInConfigured)
        #else
        #expect(!Config.isBrowserSignInAvailable)
        #endif
    }
}
