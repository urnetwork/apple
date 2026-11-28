//
//  EmailChangeModel.swift
//  URnetwork
//
//  The verified email change of the Change email sheet (sdk
//  api_email_change.go): the new address, then the code sent to the current
//  email and the one sent to the new address, and the change completes once
//  both are confirmed. The password stays the same. The sdk checks the
//  address and normalizes the codes; this model holds the sheet's step and
//  words each refusal by its code (AuthEmailChangeErrorCode*), falling back
//  to the server's message for a code this app does not know.
//
//  The routes need the network credential: without it the sdk fails the
//  request before sending it, which reads as "Sign in again", as owner_only
//  does.
//

import Foundation
import URnetworkSdk

@MainActor
final class EmailChangeModel: ObservableObject {

    enum Step: Equatable {
        /// the new address
        case enterEmail
        /// the codes sent to the current email (masked by the server) and
        /// to the new one
        case enterCodes(currentEmail: String, newEmail: String)
        /// the account's email sign-in is `email` now
        case done(email: String, otherSessionsSignedOut: Bool)
    }

    @Published private(set) var step: Step = .enterEmail

    @Published var newEmail: String = "" {
        didSet {
            errorMessage = nil
        }
    }
    @Published var currentCode: String = "" {
        didSet {
            errorMessage = nil
        }
    }
    @Published var newCode: String = "" {
        didSet {
            errorMessage = nil
        }
    }
    /// the code sent to that address was accepted: its field is done
    @Published private(set) var currentConfirmed = false
    @Published private(set) var newConfirmed = false

    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let api: UrApiServiceProtocol

    init(api: UrApiServiceProtocol) {
        self.api = api
    }

    var isDone: Bool {
        if case .done = step {
            return true
        }
        return false
    }

    var canSendCodes: Bool {
        !isBusy && !newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// every code not yet accepted is entered
    var canConfirm: Bool {
        !isBusy
            && (currentConfirmed || !currentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (newConfirmed || !newCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Asks for the change: a code to the current email and one to the new
    /// address. The address is checked here first (ValidateEmailChangeAddress).
    func sendCodes() async {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !email.isEmpty else {
            return
        }
        if !SdkValidateEmailChangeAddress(email).isEmpty {
            errorMessage = Self.text(code: SdkAuthEmailChangeErrorCodeInvalidEmail, message: "")
            return
        }
        isBusy = true
        errorMessage = nil
        let (result, err) = await api.authEmailChange(newEmail: email)
        isBusy = false
        if let err {
            errorMessage = requestFailedText(err)
            return
        }
        guard let result else {
            errorMessage = Self.genericText
            return
        }
        if let error = result.error {
            errorMessage = Self.text(code: error.code, message: error.message)
            return
        }
        currentCode = ""
        newCode = ""
        currentConfirmed = false
        newConfirmed = false
        step = .enterCodes(currentEmail: result.currentEmail, newEmail: result.newEmail)
    }

    /// Confirms with the codes not yet accepted. True once the change is
    /// complete.
    func confirm() async -> Bool {
        guard case .enterCodes = step, canConfirm else {
            return false
        }
        isBusy = true
        errorMessage = nil
        let (result, err) = await api.authEmailChangeConfirm(
            currentCode: currentConfirmed ? "" : currentCode,
            newCode: newConfirmed ? "" : newCode
        )
        isBusy = false
        // the sheet was cancelled while the codes were on their way
        guard case .enterCodes = step else {
            return false
        }
        if let err {
            errorMessage = requestFailedText(err)
            return false
        }
        guard let result else {
            errorMessage = Self.genericText
            return false
        }
        if let error = result.error {
            if error.endsRequest() {
                // nothing waits any more (expired, too many wrong codes, or
                // the address was taken): the change starts again
                step = .enterEmail
            } else if error.code == SdkAuthEmailChangeErrorCodeCodeInvalid {
                // a wrong code keeps the fields; a code accepted is done
                currentConfirmed = !result.needsCurrentCode()
                newConfirmed = !result.needsNewCode()
            }
            errorMessage = Self.text(code: error.code, message: error.message)
            return false
        }
        if result.complete {
            step = .done(email: result.email, otherSessionsSignedOut: result.otherSessionsSignedOut)
            return true
        }
        // one code accepted, the other still to enter
        currentConfirmed = !result.needsCurrentCode()
        newConfirmed = !result.needsNewCode()
        return false
    }

    /// The sheet closed while the codes were waiting: the change ends, fire
    /// and forget, so its codes stop working.
    func cancelIfWaiting() {
        guard case .enterCodes = step else {
            return
        }
        step = .enterEmail
        let api = api
        Task {
            _ = await api.authEmailChangeCancel()
        }
    }

    /// A request that failed before the server answered: without the network
    /// credential the sdk never sent it (ErrNetworkCredentialRequired).
    private func requestFailedText(_ err: Error) -> String {
        print("[EmailChange] request error: \(err.localizedDescription)")
        if !api.hasNetworkCredential() {
            return Self.text(code: SdkAuthEmailChangeErrorCodeOwnerOnly, message: "")
        }
        return Self.genericText
    }

    static var genericText: String {
        String(localized: "Something went wrong. Please try again later.")
    }

    /// The words for a refusal's code; the server's message for a code this
    /// app does not know.
    static func text(code: String, message: String) -> String {
        switch code {
        case SdkAuthEmailChangeErrorCodeOwnerOnly:
            return String(localized: "Sign in again to change your email.")
        case SdkAuthEmailChangeErrorCodeNoEmail:
            return String(localized: "Your account has no email sign-in. Add one as a sign-in method instead.")
        case SdkAuthEmailChangeErrorCodeEmailUnverified:
            return String(localized: "Verify your current email before you change it.")
        case SdkAuthEmailChangeErrorCodeInvalidEmail:
            return String(localized: "Enter a valid email address.")
        case SdkAuthEmailChangeErrorCodeSameEmail:
            return String(localized: "That's already your email.")
        case SdkAuthEmailChangeErrorCodeEmailInUse:
            return String(localized: "Another account already uses that email.")
        case SdkAuthEmailChangeErrorCodeRateLimited:
            return String(localized: "Too many tries. Please try again later.")
        case SdkAuthEmailChangeErrorCodeSendFailed:
            return String(localized: "The code could not be sent. Please try again.")
        case SdkAuthEmailChangeErrorCodeNoChange:
            return String(localized: "This email change ended before it was confirmed. Start again.")
        case SdkAuthEmailChangeErrorCodeCodeInvalid:
            return String(localized: "That code is wrong. Check it and try again.")
        case SdkAuthEmailChangeErrorCodeTooManyTries:
            return String(localized: "Too many wrong codes. Start again.")
        default:
            return message.isEmpty ? genericText : message
        }
    }
}
