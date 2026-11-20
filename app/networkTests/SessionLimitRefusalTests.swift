//
//  SessionLimitRefusalTests.swift
//  networkTests
//

import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

/**
 * A sign-in the account's cap of active sessions refuses (the result error
 * code SdkSessionErrorCodeLimitReached, sdk api_session_limit.go). Every
 * sign-in screen says there are too many active sessions and where to sign
 * the unused ones out, in the app's words, where it shows its errors: not the
 * server's message, a generic error, or a wrong one ("incorrect password").
 * Each case goes through the screen's own result path: the injected sdk
 * callbacks of the password and verification screens, the device client's
 * auth-client request, the service's refusal mapping, and the view models
 * the other screens show.
 */
@MainActor
final class SessionLimitRefusalTests: XCTestCase {

    /// The sdk's English message in the refusal, which no screen shows.
    private static let sdkMessage = "Too many active sessions. Sign out sessions you no longer use in Account > Sessions, then try again."

    /// sessions_limit_reached_sign_in
    private static let appMessage = String(localized: "Too many active sessions. On a device that's signed in to this account, go to Account > Sessions and sign out sessions you no longer use, then try again.")

    /// A service whose sign-ins and creates the server refuses with `refusal`.
    private final class RefusingService: MockUrApiService {
        private let refusal: Error

        init(_ refusal: Error) {
            self.refusal = refusal
        }

        override func authLogin(_ args: SdkAuthLoginArgs) async throws -> AuthLoginResult {
            throw refusal
        }

        override func loginWithSeedphrase(seedphrase: String) async throws -> AuthLoginResult {
            throw refusal
        }

        override func authCodeLogin(_ args: SdkAuthCodeLoginArgs) async throws -> SdkAuthCodeLoginResult {
            throw refusal
        }

        override func createInstantAccount(referralCode: String?, productUpdatesOptOut: Bool) async throws -> (jwt: String, seedphrase: String) {
            throw refusal
        }
    }

    private static func sessionLimitLoginError() -> SdkAuthLoginResultError {
        let resultError = SdkAuthLoginResultError()
        resultError.code = SdkSessionErrorCodeLimitReached
        resultError.message = sdkMessage
        return resultError
    }

    private static func sessionLimitApiError() -> SdkApiError {
        let resultError = SdkApiError()
        resultError.code = SdkSessionErrorCodeLimitReached
        resultError.message = sdkMessage
        return resultError
    }

    func testTheRefusalReadsAsTheAppsWords() {
        XCTAssertNotEqual(SessionLimitReachedError.message, Self.sdkMessage)
        XCTAssertEqual(SessionLimitReachedError.message, Self.appMessage)
        XCTAssertEqual(SessionLimitReachedError().localizedDescription, Self.appMessage)
        XCTAssertEqual(NetworkCreateError.sessionLimitReached.localizedDescription, Self.appMessage)
        XCTAssertEqual(SessionLimitReachedError.message(for: SessionLimitReachedError()), Self.appMessage)
        XCTAssertEqual(SessionLimitReachedError.message(for: NetworkCreateError.sessionLimitReached), Self.appMessage)
        // every other failure keeps its screen's own line
        XCTAssertNil(SessionLimitReachedError.message(for: NetworkCreateError.refused(message: Self.sdkMessage)))
        XCTAssertNil(SessionLimitReachedError.message(for: NSError(domain: "UrApiService", code: -1)))
        XCTAssertNil(SessionLimitReachedError.message(for: NetworkClientLimitError(offersUpgrade: true)))
    }

    // SSO (Apple, Google), wallets and the email or phone step (/auth/login)
    func testASignInRefusedAtTheCapFailsWithTheSessionLimit() async {
        let refusal = UrApiService.authLoginRefusal(Self.sessionLimitLoginError())
        XCTAssertTrue(refusal is SessionLimitReachedError)

        let model = LoginInitialView.ViewModel(urApiService: RefusingService(refusal))
        let result = await model.authLogin(args: SdkAuthLoginArgs())
        guard case .failure(let error) = result else {
            return XCTFail("a refused sign-in was not a failure")
        }
        XCTAssertEqual(SessionLimitReachedError.message(for: error), Self.appMessage)

        // any other refusal keeps the generic line
        let other = SdkAuthLoginResultError()
        other.message = "Invalid login credentials."
        XCTAssertNil(SessionLimitReachedError.message(for: UrApiService.authLoginRefusal(other)))
    }

    // the recovery phrase screen shows its failure's description
    func testARecoveryPhraseSignInRefusedAtTheCapSaysSo() async {
        let model = LoginSeedphraseView.ViewModel(urApiService: RefusingService(UrApiService.authLoginRefusal(Self.sessionLimitLoginError())))
        model.seedphrase = Array(repeating: "synthetic", count: 12).joined(separator: " ")
        let result = await model.login()
        guard case .failure(let error) = result else {
            return XCTFail("a refused sign-in was not a failure")
        }
        XCTAssertEqual(error.localizedDescription, Self.appMessage)
        XCTAssertFalse(model.isLoggingIn)
    }

    // /auth/login-with-password: the cap, not a wrong password
    func testAPasswordSignInRefusedAtTheCapIsNotAWrongPassword() async {
        let model = LoginPasswordView.ViewModel(api: SdkApi())
        model.password = "synthetic-password"
        let result = await model.loginWithPassword(userAuth: "test@example.invalid", send: { _, _, callback in
            let refused = SdkAuthLoginWithPasswordResult()
            refused.error = Self.sessionLimitApiError()
            callback.result(refused, err: nil)
        })
        guard case .failure(let error) = result else {
            return XCTFail("a refused sign-in was not a failure")
        }
        XCTAssertTrue(error is SessionLimitReachedError)
        XCTAssertEqual(SessionLimitReachedError.message(for: error), Self.appMessage)
        XCTAssertFalse(model.isLoggingIn)
    }

    // /auth/verify, after a password sign-in or a sign-up: the cap, not a
    // wrong code
    func testAVerificationRefusedAtTheCapIsNotAWrongCode() async {
        let model = CreateNetworkVerifyView.ViewModel(api: SdkApi(), userAuth: "test@example.invalid", sendNotice: .sent)
        model.otp = "123456"
        let result = await model.submit(send: { _, _, callback in
            let refused = SdkAuthVerifyResult()
            refused.error = Self.sessionLimitApiError()
            callback.result(refused, err: nil)
        })
        guard case .failure(let error) = result else {
            return XCTFail("a refused verification was not a failure")
        }
        XCTAssertTrue(error is SessionLimitReachedError)
        XCTAssertEqual(SessionLimitReachedError.message(for: error), Self.appMessage)
        XCTAssertFalse(model.isSubmitting)
    }

    // /auth/code-login: the field says the cap, not a bad code, until the
    // code changes
    func testACodeSignInRefusedAtTheCapSaysSoInsteadOfABadCode() async {
        let model = LoginAuthCodeView.ViewModel(urApiService: RefusingService(SessionLimitReachedError()))
        model.authCode = "synthetic-code"
        let result = await model.authCodeLogin()
        guard case .failure = result else {
            return XCTFail("a refused sign-in was not a failure")
        }
        XCTAssertTrue(model.loginFailed)
        XCTAssertTrue(model.sessionLimitReached)
        model.authCode = "synthetic-code-2"
        XCTAssertFalse(model.loginFailed)
        XCTAssertFalse(model.sessionLimitReached)

        // any other failure is the code's
        let other = LoginAuthCodeView.ViewModel(urApiService: RefusingService(NSError(domain: "UrApiService", code: 0)))
        other.authCode = "synthetic-code"
        _ = await other.authCodeLogin()
        XCTAssertTrue(other.loginFailed)
        XCTAssertFalse(other.sessionLimitReached)
    }

    // /auth/network-create, for a new account and an instant one
    func testANetworkCreateRefusedAtTheCapSaysSo() async {
        let refused = SdkNetworkCreateResult()
        let resultError = SdkNetworkCreateResultError()
        resultError.code = SdkSessionErrorCodeLimitReached
        resultError.message = Self.sdkMessage
        refused.error = resultError
        XCTAssertEqual(UrApiService.createNetworkRefusal(refused), .sessionLimitReached)
        XCTAssertEqual(createNetworkFailureMessage(NetworkCreateError.sessionLimitReached), Self.appMessage)
        XCTAssertEqual(createNetworkFailureMessage(NetworkCreateError.sessionLimitReached, bittensorWalletId: "taocom"), Self.appMessage)

        let model = CreateNetworkInstantView.ViewModel(urApiService: RefusingService(NetworkCreateError.sessionLimitReached))
        model.termsAgreed = true
        let created = await model.createInstantAccount()
        XCTAssertNil(created)
        XCTAssertEqual(model.errorMessage, Self.appMessage)
    }

    // /network/auth-client, the device's client right after a sign-in: no
    // client limit prompt (neither an upgrade nor a device removal frees a
    // session), no device, and the session limit's words
    func testTheDeviceClientRefusedAtTheCapIsTheSessionLimit() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let request = try f.begin()
        let result = await f.manager.authenticateNetworkClient(
            NetworkLogin(jwt: "synthetic-admin", newNetwork: false),
            request: request,
            requestClient: { _, _, callback in
                let refused = SdkAuthNetworkClientResult()
                let refusal = SdkAuthNetworkClientError()
                refusal.code = SdkSessionErrorCodeLimitReached
                refusal.message = Self.sdkMessage
                refused.error = refusal
                callback.result(refused, err: nil)
            },
            initializeDevice: { _, _ in
                XCTFail("a refused sign-in started a device")
                return false
            }
        )
        guard case .failure(let error) = result else {
            return XCTFail("a refused client was not a failure")
        }
        XCTAssertTrue(error is SessionLimitReachedError)
        XCTAssertFalse(error is NetworkClientLimitError)
        XCTAssertEqual(SessionLimitReachedError.message(for: error), Self.appMessage)
    }
}
