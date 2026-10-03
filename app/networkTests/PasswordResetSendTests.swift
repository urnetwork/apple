import XCTest
import URnetworkSdk
@testable import URnetwork

// The server reports a password reset link it did not send as `error` on
// /auth/password-reset when the request sets result_errors. The reset screens
// read only "a result came back" and said the link was sent.
final class PasswordResetSendTests: XCTestCase {
    private func result(code: String, message: String = "", retryAfterSeconds: Int = 0) -> SdkAuthPasswordResetResult {
        let sendError = SdkAuthVerifySendError()
        sendError.code = code
        sendError.message = message
        sendError.retryAfterSeconds = retryAfterSeconds
        let result = SdkAuthPasswordResetResult()
        result.userAuth = "a@example.com"
        result.error = sendError
        return result
    }

    private func notice(_ outcome: Result<VerifySendNotice, Error>) -> VerifySendNotice? {
        if case .success(let notice) = outcome {
            return notice
        }
        return nil
    }

    func testRateLimitedResetIsNotSent() {
        let outcome = passwordResetOutcome(result: result(code: SdkAuthVerifySendErrorCodeRateLimited, message: "Too many.", retryAfterSeconds: 300), err: nil)

        XCTAssertEqual(notice(outcome), .rateLimited(minutes: 5))
        XCTAssertEqual(notice(outcome)?.resetErrorMessage, String(localized: "Too many attempts. You can request a new reset link in \(5) minutes."))
    }

    func testFailedResetSendIsNotSent() {
        let outcome = passwordResetOutcome(result: result(code: SdkAuthVerifySendErrorCodeSendFailed, message: "Could not send."), err: nil)

        XCTAssertEqual(notice(outcome), .sendFailed)
        XCTAssertEqual(notice(outcome)?.resetErrorMessage, String(localized: "Error sending password reset link"))
    }

    func testUnknownCodeUsesServerMessage() {
        XCTAssertEqual(notice(passwordResetOutcome(result: result(code: "other", message: "Server says no."), err: nil)), .serverMessage("Server says no."))
    }

    func testResultWithoutErrorIsSent() {
        let sent = SdkAuthPasswordResetResult()
        sent.userAuth = "a@example.com"

        XCTAssertEqual(notice(passwordResetOutcome(result: sent, err: nil)), .sent)
        XCTAssertNil(VerifySendNotice.sent.resetErrorMessage)
    }

    func testRequestErrorIsFailure() {
        XCTAssertNil(notice(passwordResetOutcome(result: nil, err: NSError(domain: "test", code: 1))))
        XCTAssertNil(notice(passwordResetOutcome(result: nil, err: nil)))
    }

    // without result_errors the server answers a rate limit with HTTP 429 and no retry time
    func testPasswordResetArgsAskForResultErrors() {
        let args = passwordResetArgs(userAuth: "a@example.com")

        XCTAssertTrue(args.resultErrors)
        XCTAssertEqual(args.userAuth, "a@example.com")
    }
}
