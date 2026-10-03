//
//  VerifySendNotice.swift
//  URnetwork
//

import Foundation
import URnetworkSdk

// What the verify screen tells the user after asking the server to send a code.
// The server reports a code it did not send (rate limited, or the send failed) as
// `send_error` on login with password and network create, and as `error` on
// /auth/verify-send when the request sets `result_errors`. Only `sent` may say a
// code was sent.
enum VerifySendNotice: Hashable {
    case sent
    case rateLimited(minutes: Int)
    case sendFailed
    case serverMessage(String)

    static let sendFailedCode = SdkAuthVerifySendErrorCodeSendFailed
    static let rateLimitedCode = SdkAuthVerifySendErrorCodeRateLimited

    // `transportError` is any request error; `code` empty or nil means no error.
    // Localizes on the code and falls back to the server message.
    static func decide(
        transportError: Bool,
        code: String?,
        message: String?,
        retryAfterSeconds: Int
    ) -> VerifySendNotice {
        if transportError {
            return .sendFailed
        }
        guard let code = code, !code.isEmpty else {
            return .sent
        }
        if code == rateLimitedCode && 0 < retryAfterSeconds {
            // round up so the user never retries early
            return .rateLimited(minutes: max(1, (retryAfterSeconds + 59) / 60))
        }
        if code == sendFailedCode {
            return .sendFailed
        }
        if let message = message, !message.isEmpty {
            return .serverMessage(message)
        }
        return .sendFailed
    }

    static func decide(transportError: Bool, sendError: SdkAuthVerifySendError?) -> VerifySendNotice {
        return decide(
            transportError: transportError,
            code: sendError?.code,
            message: sendError?.message,
            retryAfterSeconds: sendError?.retryAfterSeconds ?? 0
        )
    }

    // nil when the code was sent
    var errorMessage: String? {
        switch self {
        case .sent:
            return nil
        case .rateLimited(let minutes):
            return String(localized: "Too many attempts. You can request a new code in \(minutes) minutes.")
        case .sendFailed:
            return String(localized: "There was an error sending the verification code.")
        case .serverMessage(let message):
            return message
        }
    }

    // the same outcome for a password reset link; nil when the link was sent
    var resetErrorMessage: String? {
        switch self {
        case .sent:
            return nil
        case .rateLimited(let minutes):
            return String(localized: "Too many attempts. You can request a new reset link in \(minutes) minutes.")
        case .sendFailed:
            return String(localized: "Error sending password reset link")
        case .serverMessage(let message):
            return message
        }
    }
}

// After a rate limit, no new code or link can be requested until `until`. The
// screens disable Resend / Send until then and count the minutes down.
struct SendCooldown: Equatable {
    let until: Date

    // nil unless the notice is a rate limit. `retryAfterSeconds` is the server's
    // retry time when known; otherwise the notice's (rounded up) minutes are used.
    static func after(_ notice: VerifySendNotice, retryAfterSeconds: Int = 0, now: Date) -> SendCooldown? {
        guard case .rateLimited(let minutes) = notice else {
            return nil
        }
        let seconds = 0 < retryAfterSeconds ? retryAfterSeconds : minutes * 60
        return SendCooldown(until: now.addingTimeInterval(TimeInterval(seconds)))
    }

    static func after(_ notice: VerifySendNotice, sendError: SdkAuthVerifySendError?, now: Date) -> SendCooldown? {
        return after(notice, retryAfterSeconds: sendError?.retryAfterSeconds ?? 0, now: now)
    }

    // whole seconds left, rounded up
    func remainingSeconds(at now: Date) -> Int {
        return max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    func isActive(at now: Date) -> Bool {
        return 0 < remainingSeconds(at: now)
    }

    // the rate limit notice with the minutes left, or nil once it has passed
    func notice(at now: Date) -> VerifySendNotice? {
        let remaining = remainingSeconds(at: now)
        if remaining <= 0 {
            return nil
        }
        return .rateLimited(minutes: max(1, (remaining + 59) / 60))
    }
}

// Every verify-send asks for the error in the result, so a rate limit carries its retry time.
func verifySendArgs(userAuth: String) -> SdkAuthVerifySendArgs {
    let args = SdkAuthVerifySendArgs()
    args.userAuth = userAuth
    args.useNumeric = true
    args.resultErrors = true
    return args
}

// Every password reset asks for the error in the result, so a link that was not
// sent is never reported as sent.
func passwordResetArgs(userAuth: String) -> SdkAuthPasswordResetArgs {
    let args = SdkAuthPasswordResetArgs()
    args.userAuth = userAuth
    args.resultErrors = true
    return args
}

enum PasswordResetSendError: Error {
    case resultInvalid
}

// A request error is a failure; otherwise the notice for the server's answer,
// where only `sent` means the link was sent.
func passwordResetOutcome(result: SdkAuthPasswordResetResult?, err: Error?) -> Result<VerifySendNotice, Error> {
    if let err = err {
        return .failure(err)
    }
    guard let result = result else {
        return .failure(PasswordResetSendError.resultInvalid)
    }
    return .success(VerifySendNotice.decide(transportError: false, sendError: result.error))
}
