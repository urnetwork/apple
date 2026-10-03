import XCTest
import URnetworkSdk
@testable import URnetwork

// The server reports a verification code it did not send as a result error;
// the verify screen must not say a code was sent.
final class VerifySendNoticeTests: XCTestCase {
    func testRateLimitedIsNotSent() {
        let notice = VerifySendNotice.decide(transportError: false, code: "verify_rate_limited", message: "Too many attempts.", retryAfterSeconds: 300)

        XCTAssertEqual(notice, .rateLimited(minutes: 5))
        XCTAssertTrue(notice.errorMessage?.contains("5") == true)
    }

    func testRateLimitedRoundsMinutesUp() {
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "verify_rate_limited", message: nil, retryAfterSeconds: 1), .rateLimited(minutes: 1))
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "verify_rate_limited", message: nil, retryAfterSeconds: 61), .rateLimited(minutes: 2))
    }

    func testRateLimitedWithoutRetryUsesServerMessage() {
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "verify_rate_limited", message: "Too many attempts.", retryAfterSeconds: 0), .serverMessage("Too many attempts."))
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "verify_rate_limited", message: "", retryAfterSeconds: 0), .sendFailed)
    }

    func testSendFailedIsNotSent() {
        let notice = VerifySendNotice.decide(transportError: false, code: "verify_send_failed", message: "Could not send.", retryAfterSeconds: 0)

        XCTAssertEqual(notice, .sendFailed)
        XCTAssertEqual(notice.errorMessage, String(localized: "There was an error sending the verification code."))
    }

    func testUnknownCodeUsesServerMessage() {
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "other", message: "Server says no.", retryAfterSeconds: 0), .serverMessage("Server says no."))
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "other", message: nil, retryAfterSeconds: 0), .sendFailed)
    }

    func testTransportErrorIsSendFailed() {
        XCTAssertEqual(VerifySendNotice.decide(transportError: true, code: nil, message: nil, retryAfterSeconds: 0), .sendFailed)
    }

    func testNoErrorIsSent() {
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: nil, message: nil, retryAfterSeconds: 0), .sent)
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, code: "", message: nil, retryAfterSeconds: 0), .sent)
        XCTAssertNil(VerifySendNotice.sent.errorMessage)
    }

    // the decoded sdk error (verification_required.send_error, verify-send `error`)
    func testSdkSendErrorIsNotSent() {
        let sendError = SdkAuthVerifySendError()
        sendError.code = SdkAuthVerifySendErrorCodeRateLimited
        sendError.message = "Too many attempts."
        sendError.retryAfterSeconds = 300

        XCTAssertEqual(VerifySendNotice.decide(transportError: false, sendError: sendError), .rateLimited(minutes: 5))
        XCTAssertEqual(VerifySendNotice.decide(transportError: false, sendError: nil), .sent)
    }

    // without result_errors the server answers a rate limit with HTTP 429 and no retry time
    func testVerifySendArgsAskForResultErrors() {
        let args = verifySendArgs(userAuth: "a@example.com")

        XCTAssertTrue(args.resultErrors)
        XCTAssertEqual(args.userAuth, "a@example.com")
        XCTAssertTrue(args.useNumeric)
    }
}
