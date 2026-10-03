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
}

// Every verify-send asks for the error in the result, so a rate limit carries its retry time.
func verifySendArgs(userAuth: String) -> SdkAuthVerifySendArgs {
    let args = SdkAuthVerifySendArgs()
    args.userAuth = userAuth
    args.useNumeric = true
    args.resultErrors = true
    return args
}
