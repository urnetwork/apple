//
//  MicrosoftSignIn.swift
//  URnetwork
//
//  Sign in with Microsoft for the login screen and the add sign-in method
//  sheet. The flow is the sdk's (MicrosoftSignInAttempt, sdk
//  oauth_microsoft.go), and no app carries a Microsoft client: the app opens
//  the attempt's start url, the api sends the browser on to Microsoft with its
//  own client, and the api's callback returns to urnetwork://oauth/microsoft
//  with the identity token or an error. Finishing the attempt with that url
//  checks its state and the token's nonce.
//
//  iOS and the macOS App Store build run the browser in an
//  ASWebAuthenticationSession, which takes the return itself. The
//  direct-download build opens the default browser, as its Google and Apple
//  browser flow does (BrowserSso): NetworkApp.onOpenURL routes the return
//  through the DeepLinkRouter to the screen whose attempt waits for it
//  (MicrosoftSignInBrowserAttempts), and an attempt nobody returns to ends
//  after BrowserSso.attemptTimeout.
//
//  A return carries an identity token, so return urls are never logged.
//

import Foundation
import AuthenticationServices
import URnetworkSdk

enum MicrosoftSignIn {

    /// The platform claim of an attempt's state; the api returns to the
    /// urnetwork scheme for both.
    static var platform: String {
        #if os(iOS)
        return SdkOAuthPlatformIos
        #else
        return SdkOAuthPlatformMacos
        #endif
    }

    /// How an attempt ended, as the screens show it.
    enum Outcome: Equatable {
        /// the identity token, for /auth/login or /auth/add-auth
        case signedIn(idToken: String)
        /// the person backed out: nothing is shown
        case cancelled
        /// a return for another attempt (a stray or replayed one): ignored,
        /// and the attempt in flight keeps waiting
        case notThisAttempt
        /// what the screen shows
        case failed(String)
    }

    static var failedText: String {
        String(localized: "Error signing in with Microsoft")
    }

    /// A new attempt for this platform, nil when the sdk could not make one.
    static func newAttempt() -> SdkMicrosoftSignInAttempt? {
        var error: NSError?
        let attempt = SdkNewMicrosoftSignInAttempt(platform, &error)
        if let error {
            print("[microsoft] could not start an attempt: \(error.localizedDescription)")
            return nil
        }
        return attempt
    }

    /// Finishes `attempt` with the url the browser returned.
    static func finish(_ attempt: SdkMicrosoftSignInAttempt, returnUrl: URL) -> Outcome {
        do {
            let result = try attempt.finish(returnUrl.absoluteString)
            return .signedIn(idToken: result.idToken)
        } catch {
            return outcome(error)
        }
    }

    /// The outcome of a return the attempt could not use, by the code its
    /// message starts with (MicrosoftSignInErrorCodeOf).
    static func outcome(_ error: Error) -> Outcome {
        let message = error.localizedDescription
        switch SdkMicrosoftSignInErrorCodeOf(message) {
        case SdkMicrosoftSignInErrorCodeNotThisAttempt:
            print("[microsoft] ignored a return: \(message)")
            return .notThisAttempt
        case SdkMicrosoftSignInErrorCodeCancelled:
            return .cancelled
        case SdkMicrosoftSignInErrorCodeNotConfigured:
            return .failed(String(localized: "Sign in with Microsoft isn't available yet. Try another way to sign in."))
        default:
            print("[microsoft] sign-in failed: \(message)")
            return .failed(failedText)
        }
    }

    /// One attempt in an authentication session over `anchor` (iOS and the
    /// macOS App Store build): the session opens the attempt's start url on
    /// `apiUrl` and hands the return back itself. The session ends with that
    /// return, so a return for another attempt ends this one too, showing
    /// nothing.
    @MainActor
    static func signInInSession(apiUrl: String, anchor: ASPresentationAnchor) async -> Outcome {
        guard let attempt = newAttempt(),
              let startUrl = URL(string: attempt.startUrl(apiUrl)) else {
            return .failed(failedText)
        }
        let session = MicrosoftSignInSession(anchor: anchor)
        switch await session.run(startUrl, callbackScheme: attempt.getReturnScheme()) {
        case .returned(let returnUrl):
            return finish(attempt, returnUrl: returnUrl)
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed(failedText)
        }
    }
}

/// One authentication session and the window it presents over. The session
/// holds its presentation provider weakly, so this object holds the session
/// and the session's completion holds this object, until the session ends.
@MainActor
private final class MicrosoftSignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum End {
        case returned(URL)
        case cancelled
        case failed
    }

    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<End, Never>?

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func run(_ url: URL, callbackScheme: String) async -> End {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { returnUrl, error in
                let end = MicrosoftSignInSession.end(returnUrl: returnUrl, error: error)
                Task { @MainActor in
                    self.finish(end)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                print("[microsoft] the authentication session did not start")
                finish(.failed)
            }
        }
    }

    /// Resumes the caller once, and lets the session go.
    private func finish(_ end: End) {
        session = nil
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(returning: end)
    }

    nonisolated private static func end(returnUrl: URL?, error: Error?) -> End {
        if let returnUrl {
            return .returned(returnUrl)
        }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            return .cancelled
        }
        print("[microsoft] the authentication session ended without a return: \(error?.localizedDescription ?? "")")
        return .failed
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// The direct-download build's Microsoft attempt in flight: one at a time,
/// with a fresh state and nonce each time, replacing any before it. Its start
/// url opens in the default browser, and the screen that started it hands it
/// the return the DeepLinkRouter holds. It ends on its own return, on cancel,
/// or after BrowserSso.attemptTimeout, as the Google and Apple browser
/// attempts do.
@MainActor
final class MicrosoftSignInBrowserAttempts {

    private var attempt: SdkMicrosoftSignInAttempt?
    private var timeoutTask: Task<Void, Never>?

    /// an attempt waits for its return
    var isPending: Bool {
        attempt != nil
    }

    /// Starts an attempt and returns the url to open, nil when none could be
    /// made. `onTimeout` runs if no return ended the attempt first.
    func begin(apiUrl: String, onTimeout: @escaping @MainActor () -> Void) -> URL? {
        cancel()
        guard let attempt = MicrosoftSignIn.newAttempt(),
              let url = URL(string: attempt.startUrl(apiUrl)) else {
            return nil
        }
        self.attempt = attempt
        let timeout = BrowserSso.attemptTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.attempt === attempt else {
                return
            }
            self.cancel()
            onTimeout()
        }
        return url
    }

    /// The outcome of a return: nil with no attempt waiting, or for another
    /// attempt's return, which leaves this one waiting. Any other outcome
    /// ends the attempt.
    func finish(_ returnUrl: URL) -> MicrosoftSignIn.Outcome? {
        guard let attempt else {
            return nil
        }
        let outcome = MicrosoftSignIn.finish(attempt, returnUrl: returnUrl)
        if outcome == .notThisAttempt {
            return nil
        }
        cancel()
        return outcome
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        attempt = nil
    }
}
