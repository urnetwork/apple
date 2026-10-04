import XCTest
import URnetworkSdk
@testable import URnetwork

// The add sign-in method sheet said an email or phone sign-in was added as soon
// as AddAuth stored it, unverified; the code came only at the first sign-in
// with it. An email or phone now counts as added only once /auth/verify accepts
// the code sent to it. Apple and Google (verified by the provider) and wallet
// (verified by its signature) need no code. The clock is injected; nothing waits.
@MainActor
final class AddedSignInVerifyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct VerifyRefused: Error {}

    private final class FakeApi: MockUrApiService {
        var sendArgs: [SdkAuthVerifySendArgs] = []
        var verifyArgs: [SdkAuthVerifyArgs] = []
        // answered in order; a send past the end answers sent
        var sendAnswers: [(result: SdkAuthVerifySendResult?, err: Error?)] = []
        var verifyAccepts = true

        override func authVerifySend(_ args: SdkAuthVerifySendArgs) async -> (result: SdkAuthVerifySendResult?, err: Error?) {
            sendArgs.append(args)
            if sendAnswers.isEmpty {
                return (SdkAuthVerifySendResult(), nil)
            }
            return sendAnswers.removeFirst()
        }

        override func authVerify(_ args: SdkAuthVerifyArgs) async throws -> SdkAuthVerifyResult {
            verifyArgs.append(args)
            if !verifyAccepts {
                throw VerifyRefused()
            }
            return SdkAuthVerifyResult()
        }
    }

    private static func sendError(code: String, message: String = "", retryAfterSeconds: Int = 0) -> (result: SdkAuthVerifySendResult?, err: Error?) {
        let sendError = SdkAuthVerifySendError()
        sendError.code = code
        sendError.message = message
        sendError.retryAfterSeconds = retryAfterSeconds
        let result = SdkAuthVerifySendResult()
        result.error = sendError
        return (result, nil)
    }

    private func model(_ api: FakeApi, _ clock: Clock) -> AddedSignInVerifyModel {
        AddedSignInVerifyModel(api: api, now: { clock.now })
    }

    // MARK: - which additions need a code

    func testOnlyEmailOrPhoneNeedsVerification() {
        XCTAssertTrue(addedSignInNeedsVerification(.email))
        XCTAssertFalse(addedSignInNeedsVerification(.apple))
        XCTAssertFalse(addedSignInNeedsVerification(.google))
        XCTAssertFalse(addedSignInNeedsVerification(.wallet))
    }

    func testProviderAndWalletAdditionsNeedNoCode() async {
        for method in [AddAuthSheetMethod.apple, .google, .wallet] {
            let api = FakeApi()
            let model = model(api, Clock(start))

            let added = await model.methodAdded(method, userAuth: "")

            XCTAssertTrue(added, "\(method.rawValue) is added when AddAuth succeeds")
            XCTAssertEqual(model.step, .verified)
            XCTAssertFalse(model.awaitingCode)
            XCTAssertTrue(api.sendArgs.isEmpty, "\(method.rawValue) sent a verification code")
            XCTAssertTrue(api.verifyArgs.isEmpty)
        }
    }

    // MARK: - an added email is verified before it counts

    func testAddedEmailIsNotAddedUntilTheCodeIsVerified() async {
        let api = FakeApi()
        let model = model(api, Clock(start))

        let added = await model.methodAdded(.email, userAuth: "a@example.com")

        XCTAssertFalse(added, "an email sign-in was reported added without verification")
        XCTAssertEqual(model.step, .enterCode(userAuth: "a@example.com"))
        XCTAssertTrue(model.awaitingCode)
        // the code is sent right away, with the send error in the result
        XCTAssertEqual(api.sendArgs.count, 1)
        XCTAssertEqual(api.sendArgs.first?.userAuth, "a@example.com")
        XCTAssertEqual(api.sendArgs.first?.resultErrors, true)
        XCTAssertEqual(api.sendArgs.first?.useNumeric, true)
        XCTAssertTrue(model.codeSent)
        XCTAssertNil(model.sendErrorMessage)

        // an incomplete code is not sent
        model.otp = "123"
        let incomplete = await model.submit()
        XCTAssertFalse(incomplete)
        XCTAssertTrue(api.verifyArgs.isEmpty)

        model.otp = "123456"
        let verified = await model.submit()

        XCTAssertTrue(verified)
        XCTAssertEqual(model.step, .verified)
        XCTAssertFalse(model.awaitingCode)
        XCTAssertEqual(api.verifyArgs.count, 1)
        XCTAssertEqual(api.verifyArgs.first?.userAuth, "a@example.com")
        XCTAssertEqual(api.verifyArgs.first?.verifyCode, "123456")
    }

    func testRefusedCodeKeepsTheSignInUnverified() async {
        let api = FakeApi()
        api.verifyAccepts = false
        let model = model(api, Clock(start))
        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        model.otp = "654321"
        let verified = await model.submit()

        XCTAssertFalse(verified)
        XCTAssertEqual(model.step, .enterCode(userAuth: "a@example.com"))
        XCTAssertEqual(model.otp, "", "the code is cleared so it can be typed again")
        XCTAssertEqual(model.otpErrorMessage, AddedSignInVerifyModel.verifyErrorMessage)

        api.verifyAccepts = true
        model.otp = "123456"
        let retried = await model.submit()
        XCTAssertTrue(retried)
        XCTAssertEqual(model.step, .verified)
    }

    // MARK: - send errors

    func testRateLimitedSendSaysWhenAndHoldsResend() async {
        let api = FakeApi()
        api.sendAnswers = [Self.sendError(code: SdkAuthVerifySendErrorCodeRateLimited, message: "Too many.", retryAfterSeconds: 300)]
        let clock = Clock(start)
        let model = model(api, clock)

        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        XCTAssertFalse(model.codeSent, "a rate-limited send must not say a code was sent")
        XCTAssertEqual(model.sendErrorMessage, VerifySendNotice.rateLimited(minutes: 5).errorMessage)
        XCTAssertEqual(model.cooldown?.until, start.addingTimeInterval(300))
        XCTAssertFalse(model.resendEnabled)
        XCTAssertEqual(model.step, .enterCode(userAuth: "a@example.com"))
    }

    func testFailedSendSaysSoAndAllowsRetry() async {
        let api = FakeApi()
        api.sendAnswers = [Self.sendError(code: SdkAuthVerifySendErrorCodeSendFailed, message: "Could not send.")]
        let model = model(api, Clock(start))

        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        XCTAssertFalse(model.codeSent)
        XCTAssertEqual(model.sendErrorMessage, String(localized: "There was an error sending the verification code."))
        XCTAssertNil(model.cooldown)
        XCTAssertTrue(model.resendEnabled)
    }

    func testUnknownSendErrorShowsTheServerMessage() async {
        let api = FakeApi()
        api.sendAnswers = [Self.sendError(code: "other", message: "Server says no.")]
        let model = model(api, Clock(start))

        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        XCTAssertFalse(model.codeSent)
        XCTAssertEqual(model.sendErrorMessage, "Server says no.")
        XCTAssertTrue(model.resendEnabled)
    }

    func testTransportErrorIsAFailedSend() async {
        let api = FakeApi()
        api.sendAnswers = [(nil, NSError(domain: "test", code: 1))]
        let model = model(api, Clock(start))

        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        XCTAssertFalse(model.codeSent)
        XCTAssertEqual(model.sendErrorMessage, String(localized: "There was an error sending the verification code."))
        XCTAssertTrue(model.resendEnabled)
    }

    // MARK: - resend cooldown

    func testResendWaitsOutTheRateLimit() async {
        let api = FakeApi()
        api.sendAnswers = [Self.sendError(code: SdkAuthVerifySendErrorCodeRateLimited, retryAfterSeconds: 300)]
        let clock = Clock(start)
        let model = model(api, clock)
        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        // refused during the cooldown; the notice counts down
        let early = await model.resend()
        XCTAssertNil(early)
        XCTAssertEqual(api.sendArgs.count, 1)

        clock.now = start.addingTimeInterval(61)
        model.tick()
        XCTAssertEqual(model.sendErrorMessage, VerifySendNotice.rateLimited(minutes: 4).errorMessage)
        XCTAssertFalse(model.resendEnabled)
        let stillEarly = await model.resend()
        XCTAssertNil(stillEarly)
        XCTAssertEqual(api.sendArgs.count, 1)

        clock.now = start.addingTimeInterval(300)
        model.tick()
        XCTAssertNil(model.cooldown)
        XCTAssertNil(model.sendErrorMessage)
        XCTAssertTrue(model.resendEnabled)

        let notice = await model.resend()
        XCTAssertEqual(notice, .sent)
        XCTAssertEqual(api.sendArgs.count, 2)
        XCTAssertTrue(model.codeSent)
    }

    func testResendIsHeldBrieflyAfterASentCode() async {
        let api = FakeApi()
        let clock = Clock(start)
        let model = model(api, clock)
        _ = await model.methodAdded(.email, userAuth: "a@example.com")

        XCTAssertFalse(model.resendEnabled)
        let held = await model.resend()
        XCTAssertNil(held)
        XCTAssertEqual(api.sendArgs.count, 1)

        clock.now = start.addingTimeInterval(AddedSignInVerifyModel.resendHoldSeconds)
        model.tick()
        XCTAssertTrue(model.resendEnabled)
        let notice = await model.resend()
        XCTAssertEqual(notice, .sent)
        XCTAssertEqual(api.sendArgs.count, 2)
    }
}
