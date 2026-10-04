//
//  AddedSignInVerifyModel.swift
//  URnetwork
//

import Foundation
import URnetworkSdk

/// The code step of the add sign-in method sheet.
///
/// AddAuth stores an email or phone sign-in unverified. The sheet used to say
/// it was added right away, and the user met the code only at their first
/// sign-in with it. Now an added email or phone gets a code at once
/// (/auth/verify-send with result_errors, so a rate limit or failed send is
/// shown instead of a claim that a code was sent), and the sign-in counts as
/// added only once /auth/verify accepts the code. Apple and Google sign-ins are
/// verified by the provider and a wallet by its signature: they count as added
/// when AddAuth succeeds (`addedSignInNeedsVerification`).
///
/// The jwt /auth/verify returns is not installed: the session already belongs
/// to this network and stays on it.
///
/// Times come from `now` so the rate-limit cooldown and the resend hold are
/// testable; the view calls `tick` every second.
@MainActor
final class AddedSignInVerifyModel: ObservableObject {

    enum Step: Equatable {
        /// no sign-in waiting for a code
        case idle
        /// an email or phone was added; it needs the code sent to it
        case enterCode(userAuth: String)
        /// verified
        case verified
    }

    let codeCount = 6

    /// after a code was sent, how long Resend waits (the login verify screen's hold)
    static let resendHoldSeconds: TimeInterval = 15

    /// shown when /auth/verify refuses the code (CreateNetworkVerifyView's text)
    static let verifyErrorMessage = "There was an error authenticating, please try again later."

    @Published private(set) var step: Step = .idle

    @Published var otp: String = "" {
        didSet {
            otpErrorMessage = nil
        }
    }

    @Published private(set) var isSending: Bool = false
    @Published private(set) var isVerifying: Bool = false
    /// false until the server confirms a code was sent
    @Published private(set) var codeSent: Bool = false
    @Published private(set) var otpErrorMessage: String?
    /// why the last send did not send a code; counts a rate limit down
    @Published private(set) var sendErrorMessage: String?
    /// set after a rate limit; Resend stays disabled until it passes
    @Published private(set) var cooldown: SendCooldown?
    @Published private(set) var resendEnabled: Bool = false

    private let api: UrApiServiceProtocol
    private let now: () -> Date
    private var resendHoldUntil: Date?

    init(api: UrApiServiceProtocol, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    var userAuth: String? {
        if case .enterCode(let userAuth) = step {
            return userAuth
        }
        return nil
    }

    /// An email or phone was added and its code step has not finished.
    var awaitingCode: Bool {
        userAuth != nil
    }

    /**
     * AddAuth succeeded for `method`. Returns true when the sign-in counts as
     * added now (Apple, Google, wallet). An email or phone goes to the code
     * step and sends its code; it counts as added once `submit` succeeds.
     */
    func methodAdded(_ method: AddAuthSheetMethod, userAuth: String) async -> Bool {
        if !addedSignInNeedsVerification(method) {
            step = .verified
            return true
        }
        step = .enterCode(userAuth: userAuth)
        otp = ""
        codeSent = false
        cooldown = nil
        resendHoldUntil = nil
        sendErrorMessage = nil
        await send()
        return false
    }

    /// Sends a new code; nil when a send is not allowed now.
    func resend() async -> VerifySendNotice? {
        guard resendEnabled else {
            return nil
        }
        return await send()
    }

    @discardableResult
    private func send() async -> VerifySendNotice? {
        guard let userAuth, !isSending else {
            return nil
        }
        isSending = true
        sendErrorMessage = nil
        updateResendEnabled()

        let (result, err) = await api.authVerifySend(verifySendArgs(userAuth: userAuth))
        if let err {
            print("[AddedSignInVerify] verify send error: \(err.localizedDescription)")
        }
        let transportError = err != nil || result == nil
        let sendError = transportError ? nil : result?.error
        let notice = VerifySendNotice.decide(transportError: transportError, sendError: sendError)

        isSending = false
        guard self.userAuth == userAuth else {
            // the step moved on while the send was in flight
            updateResendEnabled()
            return notice
        }
        if notice == .sent {
            codeSent = true
            cooldown = nil
            resendHoldUntil = now().addingTimeInterval(Self.resendHoldSeconds)
        } else {
            // a rate limit holds Resend until the retry time; any other
            // failure leaves it available so the user can retry
            cooldown = SendCooldown.after(notice, sendError: sendError, now: now())
            resendHoldUntil = nil
            sendErrorMessage = notice.errorMessage
        }
        updateResendEnabled()
        return notice
    }

    /**
     * Verifies the entered code. Returns true once the sign-in is verified;
     * on an error the code is cleared so it can be typed again.
     */
    func submit() async -> Bool {
        guard let userAuth, !isVerifying, !isSending, otp.count == codeCount else {
            return false
        }
        isVerifying = true
        otpErrorMessage = nil
        updateResendEnabled()

        let args = SdkAuthVerifyArgs()
        args.userAuth = userAuth
        args.verifyCode = otp

        var verified = false
        do {
            // the returned jwt is for this same network: not installed
            _ = try await api.authVerify(args)
            verified = true
        } catch {
            print("[AddedSignInVerify] verify error: \(error.localizedDescription)")
        }

        isVerifying = false
        guard self.userAuth == userAuth else {
            updateResendEnabled()
            return false
        }
        if verified {
            step = .verified
        } else {
            // setting otp clears the error (didSet), so set the message after.
            // The login verify screen's text, unlocalized there as well.
            otp = ""
            otpErrorMessage = Self.verifyErrorMessage
        }
        updateResendEnabled()
        return verified
    }

    /// Counts a rate limit down and ends the resend hold. The view calls it every second.
    func tick() {
        if let cooldown {
            if let notice = cooldown.notice(at: now()) {
                sendErrorMessage = notice.errorMessage
            } else {
                self.cooldown = nil
                sendErrorMessage = nil
            }
        }
        if let resendHoldUntil, resendHoldUntil <= now() {
            self.resendHoldUntil = nil
        }
        updateResendEnabled()
    }

    private func updateResendEnabled() {
        let current = now()
        let enabled = awaitingCode &&
            !isSending &&
            !isVerifying &&
            !(cooldown?.isActive(at: current) ?? false) &&
            !(resendHoldUntil.map { current < $0 } ?? false)
        if resendEnabled != enabled {
            resendEnabled = enabled
        }
    }
}
