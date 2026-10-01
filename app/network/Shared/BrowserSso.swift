//
//  BrowserSso.swift
//  URnetwork
//
//  The browser sign-in contract for Google and Apple on a build with no
//  native provider flow: the macOS direct-download build
//  (com.bringyour.urnetwork), whose Developer ID profile grants no
//  applesignin entitlement and which has no Google OAuth client of its own.
//  Mirrors linux/app/src/SsoBridge.hpp and the Windows WalletConnect: the app
//  opens the provider's own authorize page in the default browser with the
//  api's callback as the redirect, and the api answers a redirect back
//  through the urnetwork:// scheme:
//    urnetwork://oauth/<provider>?state=<state>&id_token=<identity token>
//    urnetwork://oauth/<provider>?state=<state>&error=<message>
//  The api picks the scheme from the `platform` claim inside `state`
//  (base64url JSON {"platform":"macos","token":<random>}, server
//  oauthSchemes); the state is otherwise opaque. Two checks make a return
//  usable: the echoed `state` must be the one this app minted (no stray or
//  replayed return can start a login), and the identity token's `nonce`
//  claim must be the one sent with it (the token was issued for THIS attempt,
//  not lifted from another sign-in). The token itself is never verified here:
//  /auth/login checks the signature and the audience.
//
//  Pure (Foundation only, no AppKit, no SDK) so the unit tests cover the url
//  encoding, the state round trip, the replay rejection, the nonce check and
//  the attempt timeout anywhere.
//

import Foundation

/// The two providers with a browser flow. The raw value is the auth_jwt_type
/// /auth/login takes and the path of the return url.
enum BrowserSsoProvider: String, CaseIterable, Equatable {
    case google
    case apple
}

enum BrowserSso {

    /// The platform claim of the state; the server maps it to the urnetwork scheme.
    static let platform = "macos"
    static let returnScheme = "urnetwork"
    static let returnHost = "oauth"

    // Sign in with Google (the code flow: Google only hands an identity
    // token to a server, the api's callback exchanges the code with the web
    // client's secret). The client is the ur.io web sign-in client.
    static let googleAuthorizePage = "https://accounts.google.com/o/oauth2/v2/auth"
    static let googleClientId = "338638865390-cg4m0t700mq9073smhn9do81mr640ig1.apps.googleusercontent.com"
    static let googleCallbackPath = "/auth/google/callback"
    static let googleScope = "openid email profile"

    // Sign in with Apple straight against Apple (there is no desktop SDK):
    // Apple posts code + id_token to the api's callback (form_post).
    static let appleAuthorizePage = "https://appleid.apple.com/auth/authorize"
    static let appleServicesId = "network.ur.service"
    static let appleCallbackPath = "/auth/apple/callback"
    static let appleScope = "name email"

    /// How long an attempt may wait for its return before it is stale.
    static let attemptTimeout: TimeInterval = 5 * 60

    // MARK: state

    /// The state of one attempt: base64url (unpadded) of
    /// {"platform":"macos","token":<token>}. Opaque to the provider; the api's
    /// callback reads the platform claim to pick the return scheme, the token
    /// is what makes it unique.
    static func state(token: String, platform: String = platform) -> String {
        // the key order is fixed so the state is reproducible in the tests
        let json = "{\"platform\":\(jsonString(platform)),\"token\":\(jsonString(token))}"
        return base64UrlEncode(Data(json.utf8))
    }

    /// The claims of a state this app (or the test) minted, nil for anything else.
    static func stateClaims(_ state: String) -> (platform: String, token: String)? {
        guard let data = base64UrlDecode(state),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platform = object["platform"] as? String,
              let token = object["token"] as? String else {
            return nil
        }
        return (platform, token)
    }

    // MARK: authorize urls

    /// The redirect uri of a provider's flow: the api origin the app talks to
    /// plus the callback path (a trailing slash on the origin is tolerated).
    /// This exact string must be registered with the provider (Google Cloud:
    /// authorized redirect URIs of the web client; Apple: the Services ID's
    /// return URLs).
    static func callbackURL(_ provider: BrowserSsoProvider, apiUrl: String) -> String {
        var origin = apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while origin.hasSuffix("/") {
            origin.removeLast()
        }
        switch provider {
        case .google:
            return origin + googleCallbackPath
        case .apple:
            return origin + appleCallbackPath
        }
    }

    /// The provider's authorize url for one attempt, nil without an api origin.
    static func authorizeURL(_ provider: BrowserSsoProvider, apiUrl: String, state: String, nonce: String) -> URL? {
        let redirect = callbackURL(provider, apiUrl: apiUrl)
        guard redirect.hasPrefix("https://") || redirect.hasPrefix("http://"),
              !state.isEmpty, !nonce.isEmpty else {
            return nil
        }
        let query: [(String, String)]
        let page: String
        switch provider {
        case .google:
            page = googleAuthorizePage
            query = [
                ("client_id", googleClientId),
                ("redirect_uri", redirect),
                ("response_type", "code"),
                ("scope", googleScope),
                ("state", state),
                ("nonce", nonce),
                ("prompt", "select_account"),
            ]
        case .apple:
            page = appleAuthorizePage
            query = [
                ("client_id", appleServicesId),
                ("redirect_uri", redirect),
                ("response_type", "code id_token"),
                ("response_mode", "form_post"),
                ("scope", appleScope),
                ("state", state),
                ("nonce", nonce),
            ]
        }
        return URL(string: page + "?" + encodeQuery(query))
    }

    // MARK: the return

    /// What the api's callback sent back on urnetwork://oauth/<provider>.
    struct Return: Equatable {
        let provider: BrowserSsoProvider
        let state: String
        let idToken: String
        let error: String
    }

    /// The return a url carries, nil for any other url the app opens.
    static func parseReturn(_ url: URL) -> Return? {
        guard url.scheme?.lowercased() == returnScheme,
              url.host?.lowercased() == returnHost,
              let name = url.pathComponents.dropFirst().first?.lowercased(),
              let provider = BrowserSsoProvider(rawValue: name) else {
            return nil
        }
        // the server builds the query with Go's url.Values.Encode, which
        // writes a space as "+" (an error message has them), so the query is
        // read form-style rather than through URLComponents.queryItems
        let params = parseQuery(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        return Return(
            provider: provider,
            state: params["state"] ?? "",
            idToken: params["id_token"] ?? "",
            error: params["error"] ?? ""
        )
    }

    /// Why a return was not accepted.
    enum Failure: Error, Equatable {
        /// No attempt in flight: a stray or late return, nothing to fail.
        case noAttempt
        /// The echoed state is not the attempt's: a stray or replayed return,
        /// the attempt in flight stays untouched.
        case unexpectedReturn
        /// The provider's own message (the user cancelled, Apple sent no token, ...).
        case provider(String)
        case providerMismatch
        case noToken
        /// The token was not minted for this attempt's nonce.
        case nonceMismatch
        /// The attempt waited longer than `attemptTimeout`.
        case expired

        /// A return nobody is waiting for: logged, never shown.
        var isStray: Bool {
            switch self {
            case .noAttempt, .unexpectedReturn:
                return true
            default:
                return false
            }
        }
    }

    /// One Google or Apple attempt in flight.
    struct Attempt: Equatable {
        let provider: BrowserSsoProvider
        let state: String
        let nonce: String
        let startedAt: Date

        func isExpired(at now: Date, timeout: TimeInterval = attemptTimeout) -> Bool {
            now.timeIntervalSince(startedAt) > timeout
        }
    }

    /// Accept a return only for the attempt in flight: the minted state
    /// echoed, the same provider, a token present, and the token minted for
    /// this nonce. The identity token on success.
    static func check(_ r: Return, attempt: Attempt?, now: Date = Date(), timeout: TimeInterval = attemptTimeout) -> Result<String, Failure> {
        guard let attempt else {
            return .failure(.noAttempt)
        }
        if r.state.isEmpty || r.state != attempt.state {
            return .failure(.unexpectedReturn)
        }
        if attempt.isExpired(at: now, timeout: timeout) {
            return .failure(.expired)
        }
        if !r.error.isEmpty {
            return .failure(.provider(r.error))
        }
        if r.provider != attempt.provider {
            return .failure(.providerMismatch)
        }
        if r.idToken.isEmpty {
            return .failure(.noToken)
        }
        guard jwtClaim(r.idToken, "nonce") == attempt.nonce else {
            return .failure(.nonceMismatch)
        }
        return .success(r.idToken)
    }

    // MARK: jwt

    /// One string claim of a JWT payload: decoded, never verified. The
    /// server verifies the signature; the app only reads the nonce it
    /// minted back.
    static func jwtClaim(_ jwt: String, _ claim: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let data = base64UrlDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[claim] as? String
    }

    // MARK: encoding

    /// Percent-encodes everything but the unreserved characters, like the
    /// desktop apps, so a redirect uri or a state survives the provider's
    /// parsing exactly.
    static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// A form-style query: percent escapes and "+" (a space) decoded.
    static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeForm(String(keyValue[0]))
            let value = keyValue.count > 1 ? decodeForm(String(keyValue[1])) : ""
            out[key] = value
        }
        return out
    }

    private static func decodeForm(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url (RFC 4648 §5, padded or not; the standard alphabet is
    /// tolerated too) -> bytes, nil on a bad character.
    static func base64UrlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64 += "="
        }
        return Data(base64Encoded: b64)
    }

    private static func jsonString(_ s: String) -> String {
        // JSONSerialization's own escaping, so a quote or a backslash in a
        // token cannot break the object
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

/// The attempt in flight: one at a time, a fresh state + nonce per attempt,
/// never reused, so the return is accepted exactly once and only for this
/// attempt. A stale attempt (older than the timeout) is dropped the next
/// time the store is asked about it.
final class BrowserSsoAttemptStore {

    let timeout: TimeInterval
    private(set) var pending: BrowserSso.Attempt?

    init(timeout: TimeInterval = BrowserSso.attemptTimeout) {
        self.timeout = timeout
    }

    /// Starts an attempt, replacing any attempt in flight (its return is
    /// then a replay and rejected).
    @discardableResult
    func begin(_ provider: BrowserSsoProvider, now: Date = Date()) -> BrowserSso.Attempt {
        let attempt = BrowserSso.Attempt(
            provider: provider,
            state: BrowserSso.state(token: Self.randomToken()),
            nonce: Self.randomToken(),
            startedAt: now
        )
        pending = attempt
        return attempt
    }

    /// The attempt in flight, after dropping it when it is stale.
    func current(now: Date = Date()) -> BrowserSso.Attempt? {
        if let attempt = pending, attempt.isExpired(at: now, timeout: timeout) {
            pending = nil
        }
        return pending
    }

    /// Whether `attempt` is still the one in flight (not replaced, cancelled
    /// or expired).
    func isPending(_ attempt: BrowserSso.Attempt, now: Date = Date()) -> Bool {
        current(now: now) == attempt
    }

    /// Checks a return against the attempt in flight and ends the attempt
    /// when the return echoes its state, success or not; a stray return (no
    /// attempt, another state) leaves a live attempt untouched.
    func take(_ r: BrowserSso.Return, now: Date = Date()) -> Result<String, BrowserSso.Failure> {
        let attempt = pending
        let verdict = BrowserSso.check(r, attempt: attempt, now: now, timeout: timeout)
        if let attempt, r.state == attempt.state || attempt.isExpired(at: now, timeout: timeout) {
            pending = nil
        }
        return verdict
    }

    func cancel() {
        pending = nil
    }

    private static func randomToken() -> String {
        UUID().uuidString.lowercased()
    }
}

extension BrowserSso.Failure {
    /// What the user sees when the attempt failed (never for a stray return).
    var userMessage: String {
        switch self {
        case .provider(let message):
            return message
        case .expired:
            return String(localized: "Sign-in timed out. Please try again.")
        case .noAttempt, .unexpectedReturn, .providerMismatch, .noToken, .nonceMismatch:
            return String(localized: "There was an error logging in")
        }
    }
}
