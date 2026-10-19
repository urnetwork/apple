import AuthenticationServices
import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

private final class OuterLoginService: MockUrApiService {
    var login: (SdkAuthLoginArgs) async throws -> AuthLoginResult = { _ in fatalError("unexpected login") }
    var seed: () async throws -> AuthLoginResult = { fatalError("unexpected seed login") }
    var code: () async throws -> SdkAuthCodeLoginResult = { fatalError("unexpected code login") }
    var create: () async throws -> LoginNetworkResult = { fatalError("unexpected create") }
    var instant: () async throws -> (jwt: String, seedphrase: String) = { fatalError("unexpected instant") }
    var challenge: () async throws -> SdkAuthWalletChallengeResult = { fatalError("unexpected challenge") }
    override func authLogin(_ args: SdkAuthLoginArgs) async throws -> AuthLoginResult { try await login(args) }
    override func loginWithSeedphrase(seedphrase: String) async throws -> AuthLoginResult { try await seed() }
    override func authCodeLogin(_ args: SdkAuthCodeLoginArgs) async throws -> SdkAuthCodeLoginResult { try await code() }
    override func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult { try await create() }
    override func createInstantAccount(referralCode: String?, productUpdatesOptOut: Bool) async throws -> (jwt: String, seedphrase: String) { try await instant() }
    override func authWalletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult { try await challenge() }
}

@MainActor
final class NetworkLoginProducerOwnershipTests: XCTestCase {
    private let failure = NSError(domain: "synthetic-outer-producer", code: 1)

    private func password(stale: Bool, error: Bool, duplicate: Bool = false) async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let request = try f.begin()
        let model = LoginPasswordView.ViewModel(api: f.manager.api)
        model.password = "synthetic-password"
        let started = XCTestExpectation(description: "password callback captured")
        var callback: SdkAuthLoginWithPasswordCallbackProtocol?
        let work = Task { await model.loginWithPassword(userAuth: "test@example.invalid", request: request, send: { api, _, result in
            XCTAssertTrue(api === request.api)
            callback = result
            started.fulfill()
        }) }
        let reached = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(reached, .completed)
        if stale { _ = try f.begin() }
        let result = SdkAuthLoginWithPasswordResult()
        let network = SdkAuthLoginWithPasswordResultNetwork()
        network.byJwt = "synthetic-password-admin"
        result.network = network
        if error { callback?.result(nil, err: failure) }
        else { callback?.result(result, err: nil) }
        if duplicate {
            callback?.result(result, err: nil)
            callback?.result(nil, err: failure)
        }
        let answer = await work.value
        if stale {
            guard case .failure(let error) = answer else { return XCTFail("stale password result survived") }
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(model.isLoggingIn, "stale completion must not update screen state")
            XCTAssertEqual(f.registrations, 0)
        } else if error {
            guard case .failure = answer else { return XCTFail("current failure lost") }
            XCTAssertFalse(model.isLoggingIn)
        } else {
            guard case .successWithJwt(let jwt) = answer else { return XCTFail("current password login lost") }
            _ = await f.register(request, jwt: jwt)
            XCTAssertFalse(model.isLoggingIn)
            XCTAssertEqual(f.state.getByJwt(), "synthetic-password-admin")
        }
    }
    func testPasswordLateSuccessIsRejectedBeforeRegistration() async throws { try await password(stale: true, error: false) }
    func testPasswordLateFailureCannotPublish() async throws { try await password(stale: true, error: true) }
    func testPasswordCurrentSuccessAndDuplicateNativeResult() async throws { try await password(stale: false, error: false, duplicate: true) }
    func testPasswordCurrentFailureAndDuplicateNativeResult() async throws { try await password(stale: false, error: true, duplicate: true) }

    private func verification(stale: Bool, error: Bool, duplicate: Bool = false) async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let request = try f.begin()
        let model = CreateNetworkVerifyView.ViewModel(api: f.manager.api, userAuth: "test@example.invalid", sendNotice: .sent)
        model.otp = "123456"
        let started = XCTestExpectation(description: "verification callback captured")
        var callback: SdkAuthVerifyCallbackProtocol?
        let work = Task { await model.submit(request: request, send: { api, _, result in
            XCTAssertTrue(api === request.api)
            callback = result
            started.fulfill()
        }) }
        let reached = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(reached, .completed)
        if stale { f.manager.setActiveNetworkSpace(f.other) }
        let result = SdkAuthVerifyResult()
        let network = SdkAuthVerifyResultNetwork()
        network.byJwt = "synthetic-verify-admin"
        result.network = network
        if error { callback?.result(nil, err: failure) }
        else { callback?.result(result, err: nil) }
        if duplicate { callback?.result(result, err: nil); callback?.result(nil, err: failure) }
        let answer = await work.value
        if stale {
            guard case .failure(let error) = answer else { return XCTFail("stale verification survived") }
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(model.isSubmitting)
        } else if error {
            guard case .failure = answer else { return XCTFail("current verification failure lost") }
            XCTAssertFalse(model.isSubmitting)
        } else {
            guard case .success(let jwt) = answer else { return XCTFail("current verification lost") }
            _ = await f.register(request, jwt: jwt, created: true)
            XCTAssertEqual(f.state.getByJwt(), "synthetic-verify-admin")
            XCTAssertTrue(f.state.getCanPromptIntroFunnel())
            XCTAssertFalse(model.isSubmitting)
        }
    }
    func testVerificationLateSuccessIsRejected() async throws { try await verification(stale: true, error: false) }
    func testVerificationLateFailureCannotPublish() async throws { try await verification(stale: true, error: true) }
    func testVerificationCurrentSuccessAndDuplicateNativeResult() async throws { try await verification(stale: false, error: false, duplicate: true) }
    func testVerificationCurrentFailureAndDuplicateNativeResult() async throws { try await verification(stale: false, error: true, duplicate: true) }

    func testAllInitialAuthProducersRetainRequestThroughHeldResult() async throws {
        for provider in ["password-prompt", "apple", "google", "solana", "bittensor"] {
            for stale in [false, true] {
                let f = try OuterLoginFixture(); defer { f.close() }
                let request = try f.begin()
                let held = OuterHeldResult<AuthLoginResult>()
                let service = OuterLoginService()
                service.login = { _ in try await held.wait() }
                let model = LoginInitialView.ViewModel(urApiService: service)
                let args = SdkAuthLoginArgs(); args.authJwtType = provider
                let work = Task { await model.authLogin(args: args, request: request) }
                await held.reach()
                if stale { f.manager.setActiveNetworkSpace(f.other) }
                held.finish(.success(.login("synthetic-" + provider)))
                let answer = await work.value
                if stale {
                    guard case .failure(let error) = answer else { XCTFail("stale \(provider) result survived"); continue }
                    XCTAssertTrue(error is CancellationError)
                    XCTAssertEqual(f.registrations, 0)
                } else {
                    guard case .login(let jwt) = answer else { XCTFail("current \(provider) lost"); continue }
                    _ = await f.register(request, jwt: jwt)
                    XCTAssertEqual(f.state.getByJwt(), "synthetic-" + provider)
                }
            }
        }
    }

    func testAuthCodeLateSuccessAndFailureDoNotUpdateStateAndCurrentWorks() async throws {
        for stale in [false, true] { for failed in [false, true] {
            let f = try OuterLoginFixture(); defer { f.close() }
            let request = try f.begin()
            let service = OuterLoginService(); let held = OuterHeldResult<SdkAuthCodeLoginResult>()
            service.code = { try await held.wait() }
            let model = LoginAuthCodeView.ViewModel(urApiService: service)
            model.authCode = "synthetic-code"
            let work = Task { await model.authCodeLogin(request: request) }
            await held.reach()
            if stale { _ = try f.begin() }
            let result = SdkAuthCodeLoginResult(); result.jwt = "synthetic-code-admin"
            held.finish(failed ? .failure(failure) : .success(result))
            let answer = await work.value
            XCTAssertEqual(model.isLoading, stale)
            XCTAssertEqual(model.loginFailed, failed && !stale)
            if stale { guard case .failure(let error) = answer else { XCTFail("stale code survived"); continue }; XCTAssertTrue(error is CancellationError) }
            else if !failed { guard case .success(let value) = answer else { XCTFail("current code lost"); continue }; _ = await f.register(request, jwt: value.jwt); XCTAssertEqual(f.registrations, 1) }
        } }
    }

    func testSeedphraseLateResultCannotRegisterAndCurrentWorks() async throws {
        for stale in [false, true] {
            let f = try OuterLoginFixture(); defer { f.close() }
            let request = try f.begin(); let service = OuterLoginService(); let held = OuterHeldResult<AuthLoginResult>()
            service.seed = { try await held.wait() }
            let model = LoginSeedphraseView.ViewModel(urApiService: service)
            model.seedphrase = Array(repeating: "synthetic", count: 12).joined(separator: " ")
            let work = Task { await model.login(request: request) }
            await held.reach(); if stale { _ = try f.begin() }
            held.finish(.success(.login("synthetic-seed-admin")))
            let answer = await work.value
            XCTAssertEqual(model.isLoggingIn, stale)
            if stale { guard case .failure(let error) = answer else { XCTFail("stale seed survived"); continue }; XCTAssertTrue(error is CancellationError) }
            else { guard case .login(let jwt) = answer else { XCTFail("current seed lost"); continue }; _ = await f.register(request, jwt: jwt); XCTAssertEqual(f.registrations, 1) }
        }
    }

    func testInstantCreateLateSuccessAndFailureDoNotPublishAndCurrentWorks() async throws {
        for stale in [false, true] { for failed in [false, true] {
            let f = try OuterLoginFixture(); defer { f.close() }
            let request = try f.begin(); let service = OuterLoginService(); let held = OuterHeldResult<(jwt: String, seedphrase: String)>()
            service.instant = { try await held.wait() }
            let model = CreateNetworkInstantView.ViewModel(urApiService: service); model.termsAgreed = true
            let work = Task { await model.createInstantAccount(request: request) }
            await held.reach(); if stale { _ = try f.begin() }
            held.finish(failed ? .failure(failure) : .success(("synthetic-instant-admin", "synthetic seed")))
            let answer = await work.value
            XCTAssertEqual(model.isCreatingAccount, stale)
            XCTAssertEqual(model.errorMessage != nil, failed && !stale)
            if stale || failed { XCTAssertNil(answer) }
            else { let value = try XCTUnwrap(answer); _ = await f.register(request, jwt: value.jwt, created: true); XCTAssertTrue(f.state.getCanPromptIntroFunnel()) }
        } }
    }

    func testCreateNetworkLateSuccessAndFailureDoNotPublishAndCurrentWorks() async throws {
        for stale in [false, true] { for failed in [false, true] {
            let f = try OuterLoginFixture(); defer { f.close() }
            let request = try f.begin(); let service = OuterLoginService(); let held = OuterHeldResult<LoginNetworkResult>()
            service.create = { try await held.wait() }
            var scheduled: [() -> Void] = []
            let model = CreateNetworkView.ViewModel(api: request.api, urApiService: service, authType: .apple, checkNetworkName: { _, reply in reply(true) }, schedule: { delay, work in
                if delay == NetworkNameCheck.debounceDelay { scheduled.append(work) }
                return {}
            })
            model.termsAgreed = true; model.networkName = "syntheticnetwork"
            scheduled.removeFirst()(); XCTAssertTrue(model.formIsValid)
            let work = Task { await model.createNetwork(userAuth: nil, authJwt: "synthetic-provider", authType: "apple", walletAuth: nil, request: request) }
            await held.reach(); if stale { _ = try f.begin() }
            held.finish(failed ? .failure(failure) : .success(.successWithJwt("synthetic-created-admin")))
            let answer = await work.value
            XCTAssertEqual(model.isCreatingNetwork, stale)
            if stale { guard case .failure(let error) = answer else { XCTFail("stale create survived"); continue }; XCTAssertTrue(error is CancellationError) }
            else if !failed { guard case .successWithJwt(let jwt) = answer else { XCTFail("current create lost"); continue }; _ = await f.register(request, jwt: jwt, created: true); XCTAssertTrue(f.state.getCanPromptIntroFunnel()) }
        } }
    }

    func testSolanaChallengeHeldAcrossReplacementNeverPresentsMessage() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let request = try f.begin(); let service = OuterLoginService(); let held = OuterHeldResult<SdkAuthWalletChallengeResult>()
        service.challenge = { try await held.wait() }
        let model = LoginInitialView.ViewModel(urApiService: service)
        let work = Task { await model.prepareSolanaChallenge(request: request) }
        await held.reach(); _ = try f.begin()
        let result = SdkAuthWalletChallengeResult(); result.messageTemplate = "old challenge"
        held.finish(.success(result))
        let completed = await work.value
        XCTAssertFalse(completed)
        XCTAssertNil(model.solanaChallengeMessage)
    }

    func testBittensorChallengeHeldAcrossReplacementNeverOpensBrowser() async throws {
        for stale in [false, true] { for purpose in [SdkBittensorWalletPurposeLogin, SdkBittensorWalletPurposeCreate] {
            let f = try OuterLoginFixture(); defer { f.close() }
            let request = try f.begin(); let held = OuterHeldResult<SdkAuthWalletChallengeResult>()
            var opened = 0
            let connector = BittensorWalletConnector(platform: SdkBittensorWalletPlatformMacos, fetchChallenge: { _ in try await held.wait() }, openUrl: { _ in opened += 1; return true }, now: { 1_757_340_000_000 })
            let work = Task { await connector.choose(walletId: SdkBittensorWalletTalisman, purpose: purpose, isCurrent: { request.isCurrent }) }
            await held.reach()
            let heldStage = connector.stage
            if stale { f.manager.setActiveNetworkSpace(f.other) }
            let result = SdkAuthWalletChallengeResult()
            result.messageTemplate = "Sign in to URnetwork\nChallenge: synthetic-outer-login\nTimestamp: 1757340000"
            result.expiresIn = 300
            held.finish(.success(result)); await work.value
            XCTAssertEqual(opened, stale ? 0 : 1)
            if stale { XCTAssertEqual(connector.stage, heldStage) }
            else { XCTAssertEqual(connector.stage, .awaitingBrowser(walletId: SdkBittensorWalletTalisman)) }
        } }
    }

    func testNativeAppleLateFailureStaysWithOriginalInvocationAndCurrentRetryWorks() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let oldRequest = try f.begin(); let old = NetworkLoginAppleAttempt()
        old.begin(ASAuthorizationAppleIDProvider().createRequest(), request: { oldRequest })
        var queued: [@MainActor () async -> Void] = []
        var published: [UUID] = []
        let deliver: @MainActor (Result<ASAuthorization, Error>, NetworkLoginRequest) async -> Void = { _, request in published.append(request.id) }
        XCTAssertTrue(old.complete(.failure(failure), enqueue: { queued.append($0) }, handle: deliver))
        let newRequest = try f.begin(); let current = NetworkLoginAppleAttempt()
        current.begin(ASAuthorizationAppleIDProvider().createRequest(), request: { newRequest })
        XCTAssertFalse(old.complete(.failure(failure), enqueue: { queued.append($0) }, handle: deliver))
        await queued.removeFirst()()
        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(current.complete(.failure(failure), enqueue: { queued.append($0) }, handle: deliver))
        await queued.removeFirst()()
        XCTAssertEqual(published, [newRequest.id])
    }

    func testSolanaCurrentErrorResetsAndRetryWorksWhileOldErrorCannotResetRetry() throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let request = try f.begin(); let model = LoginInitialView.ViewModel(urApiService: OuterLoginService())
        let old = NetworkLoginWalletAttempt(request: request, message: "challenge")
        func url(_ attempt: NetworkLoginWalletAttempt, host: String = "phantom-sign-message") throws -> URL {
            try XCTUnwrap(URL(string: NetworkLoginWalletAttempt.redirectLink("urnetwork://" + host, attemptId: attempt.id) + "?errorCode=user_rejected"))
        }
        model.setIsSigningMessage(true); model.setPresentSigninWithSolanaSheet(true)
        XCTAssertTrue(old.fail(try url(old)) { model.finishSolanaAttempt(request: request) })
        XCTAssertFalse(model.isSigningMessage)
        XCTAssertFalse(model.presentSigninWithSolanaSheet)
        let current = NetworkLoginWalletAttempt(request: request, message: "new challenge")
        model.setIsSigningMessage(true); model.setPresentSigninWithSolanaSheet(true)
        XCTAssertFalse(current.fail(try url(old)) { model.finishSolanaAttempt(request: request) })
        XCTAssertTrue(model.isSigningMessage)
        XCTAssertTrue(model.presentSigninWithSolanaSheet)
        XCTAssertTrue(current.fail(try url(current, host: "solflare-sign-message")) { model.finishSolanaAttempt(request: request) })
        XCTAssertFalse(model.isSigningMessage)
    }
    func testLateInitialAndSeedphraseFailuresBecomeCancellation() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let initialRequest = try f.begin()
        let service = OuterLoginService(); let heldInitial = OuterHeldResult<AuthLoginResult>()
        service.login = { _ in try await heldInitial.wait() }
        let initial = LoginInitialView.ViewModel(urApiService: service)
        let initialWork = Task { await initial.authLogin(args: SdkAuthLoginArgs(), request: initialRequest) }
        await heldInitial.reach(); _ = try f.begin(); heldInitial.finish(.failure(failure))
        if case .failure(let error) = await initialWork.value { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("old initial failure survived") }
        let seedRequest = try f.begin(); let heldSeed = OuterHeldResult<AuthLoginResult>()
        service.seed = { try await heldSeed.wait() }
        let seed = LoginSeedphraseView.ViewModel(urApiService: service)
        seed.seedphrase = Array(repeating: "synthetic", count: 12).joined(separator: " ")
        let seedWork = Task { await seed.login(request: seedRequest) }
        await heldSeed.reach(); _ = try f.begin(); heldSeed.finish(.failure(failure))
        if case .failure(let error) = await seedWork.value { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("old seed failure survived") }
    }

    func testNetworkCreateNativeCallbackIsOneShotUnderConcurrentDuplicateDelivery() {
        let counter = OuterLockedCounter()
        let callback = NetworkCreateCallback { _, _ in counter.increment() }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in callback.result(nil, err: NSError(domain: "synthetic", code: 1)) }
        XCTAssertEqual(counter.value, 1)
    }

}

private final class OuterLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
