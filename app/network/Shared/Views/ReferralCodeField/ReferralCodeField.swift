//
//  ReferralCodeField.swift
//  URnetwork
//
//  The always-visible, optional referral code field at sign-up (support inbox
//  1698), as the Windows sign-up shows it above Continue. It used to sit
//  behind a faint "Add referral code" button under Continue that opened a
//  sheet, and invitees missed it. Shared by the create-network and instant
//  account screens.
//

import Foundation
import SwiftUI
import URnetworkSdk

/// What the server has said about the code in the field.
enum ReferralCodeVerdict: Equatable {
    /// typed, not asked about yet (or the field is empty)
    case unchecked
    case checking
    case valid
    case invalid
    /// valid, but the code has reached its referral cap
    case capped
    /// the check did not answer (no network, a rate limit, a server error)
    case checkFailed
}

/// What the typed text means. Pure so networkTests pins it.
enum ReferralCodeField {

    /// The pause after typing before the code is checked (as on Windows).
    static let checkDelay: Duration = .milliseconds(400)

    /// The code as the server reads it: trimmed, upper case (the server
    /// upper-cases codes).
    static func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Only a non-empty code is worth a check.
    static func shouldCheck(_ input: String) -> Bool {
        !normalize(input).isEmpty
    }

    /// The verdict for a check's answer.
    static func verdict(valid: Bool, capped: Bool) -> ReferralCodeVerdict {
        if capped {
            return .capped
        }
        return valid ? .valid : .invalid
    }

    /// The code the create call carries: the normalized code, unless the
    /// server already said it is invalid or used up. A code that is still
    /// unchecked (Continue right after typing) or whose check did not answer
    /// goes along: the server checks it again on create and ignores a bad
    /// one, so a typed code is never dropped without a word.
    static func createCode(input: String, verdict: ReferralCodeVerdict) -> String? {
        let code = normalize(input)
        if code.isEmpty {
            return nil
        }
        switch verdict {
        case .invalid, .capped:
            return nil
        default:
            return code
        }
    }
}

/// The field's code and its checks: typing checks the code after a pause, and
/// an answer for text that has changed since is dropped.
@MainActor
final class ReferralCodeEntry: ObservableObject {

    @Published var code: String = "" {
        didSet {
            edited(from: oldValue)
        }
    }

    @Published private(set) var verdict: ReferralCodeVerdict = .unchecked

    private let validate: (String) async throws -> SdkValidateReferralCodeResult
    private let checkDelay: Duration

    // a typed code is a new edit; answers carry the edit they were asked for
    private var edit = 0
    private var pendingCheck: Task<Void, Never>?

    init(
        checkDelay: Duration = ReferralCodeField.checkDelay,
        validate: @escaping (String) async throws -> SdkValidateReferralCodeResult
    ) {
        self.checkDelay = checkDelay
        self.validate = validate
    }

    /// The code the create call carries (ReferralCodeField.createCode).
    var createCode: String? {
        ReferralCodeField.createCode(input: code, verdict: verdict)
    }

    /// The server accepted the code: the gold chip shows.
    var isApplied: Bool {
        verdict == .valid
    }

    var supportingText: LocalizedStringKey {
        switch verdict {
        case .checkFailed:
            return "Something went wrong. Please try again later."
        case .capped:
            return "This code has been used up"
        case .invalid:
            return "This code is not valid"
        default:
            return ""
        }
    }

    var validationState: ValidationState {
        switch verdict {
        case .unchecked:
            return .notChecked
        case .checking:
            return .validating
        case .valid:
            return .valid
        case .invalid, .capped, .checkFailed:
            return .invalid
        }
    }

    /// Checks the code now (Return on the keyboard, a code a link filled in).
    func checkNow() async {
        pendingCheck?.cancel()
        pendingCheck = nil
        await check()
    }

    private func edited(from oldValue: String) {
        guard ReferralCodeField.normalize(code) != ReferralCodeField.normalize(oldValue) else {
            return
        }
        edit += 1
        verdict = .unchecked
        pendingCheck?.cancel()
        pendingCheck = nil
        guard ReferralCodeField.shouldCheck(code) else {
            return
        }
        let delay = checkDelay
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            await self?.check()
        }
    }

    private func check() async {
        let normalized = ReferralCodeField.normalize(code)
        // nothing to check, or the check for this text is already out
        guard !normalized.isEmpty, verdict != .checking else {
            return
        }
        let asked = edit
        verdict = .checking
        do {
            let result = try await validate(normalized)
            // the text changed while the check was out: its answer is stale
            guard asked == edit else {
                return
            }
            verdict = ReferralCodeField.verdict(valid: result.isValid, capped: result.isCapped)
        } catch {
            guard asked == edit else {
                return
            }
            print("[ReferralCodeEntry] validate referral code error: \(error.localizedDescription)")
            verdict = .checkFailed
        }
    }
}

/// The optional referral code field above Continue, with the gold chip once
/// the server accepts the code.
struct ReferralCodeFieldView: View {

    @ObservedObject var entry: ReferralCodeEntry
    var isEnabled: Bool = true
    var accessibilityIdentifier: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            UrTextField(
                text: $entry.code,
                label: "Referral code (optional)",
                placeholder: "Enter a bonus referral code",
                supportingText: entry.supportingText,
                isEnabled: isEnabled,
                validationState: entry.validationState,
                submitLabel: .done,
                onSubmit: {
                    Task {
                        await entry.checkNow()
                    }
                },
                disableCapitalization: true,
                accessibilityIdentifier: accessibilityIdentifier,
                disableAutocorrection: true
            )

            if entry.isApplied {

                Spacer().frame(height: 16)

                ReferralAppliedChip()
            }
        }
    }
}
