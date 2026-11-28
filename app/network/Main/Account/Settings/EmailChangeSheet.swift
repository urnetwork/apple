//
//  EmailChangeSheet.swift
//  URnetwork
//
//  Change email, from the account's sign-in methods while it has an email
//  sign-in (NetworkUser.EmailSignIn). The steps are EmailChangeModel's: the
//  new address, the two codes, and the new email once both are confirmed,
//  when the account's sign-in methods are read again. Cancel on the codes
//  step, or closing the sheet there, ends the waiting change.
//

import SwiftUI
import URnetworkSdk

struct EmailChangeSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: EmailChangeModel
    let networkUserViewModel: NetworkUserViewModel?

    init(api: UrApiServiceProtocol, networkUserViewModel: NetworkUserViewModel?) {
        _model = StateObject(wrappedValue: EmailChangeModel(api: api))
        self.networkUserViewModel = networkUserViewModel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    Text("Change your email")
                        .font(themeManager.currentTheme.titleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    switch model.step {
                    case .enterEmail:
                        emailStep
                    case .enterCodes(let currentEmail, let newEmail):
                        codesStep(currentEmail: currentEmail, newEmail: newEmail)
                    case .done(let email, let otherSessionsSignedOut):
                        doneStep(email: email, otherSessionsSignedOut: otherSessionsSignedOut)
                    }

                    if let error = model.errorMessage {
                        Text(verbatim: error)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !model.isDone {
                        Button("Cancel") {
                            close()
                        }
                    }
                }
            }
        }
        .onDisappear {
            // closed on the codes step, by Cancel or by a swipe
            model.cancelIfWaiting()
        }
    }

    private func close() {
        model.cancelIfWaiting()
        dismiss()
    }

    @ViewBuilder
    private var emailStep: some View {
        Text("Enter your new email. We'll send a code to your current email and another to the new one. Your email changes when you enter both. Your password stays the same.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)

        #if os(iOS)
        UrTextField(
            text: $model.newEmail,
            label: "New email",
            placeholder: "your@email.com",
            isEnabled: !model.isBusy,
            keyboardType: .emailAddress,
            disableCapitalization: true
        )
        #else
        UrTextField(
            text: $model.newEmail,
            label: "New email",
            placeholder: "your@email.com",
            isEnabled: !model.isBusy,
            disableCapitalization: true
        )
        #endif

        UrButton(
            text: "Send codes",
            action: {
                Task {
                    await model.sendCodes()
                }
            },
            enabled: model.canSendCodes,
            isProcessing: model.isBusy
        )
    }

    @ViewBuilder
    private func codesStep(currentEmail: String, newEmail: String) -> some View {
        Text("We sent a code to \(currentEmail) and another to \(newEmail).")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)

        codeField(text: $model.currentCode, sentTo: currentEmail, confirmed: model.currentConfirmed)

        codeField(text: $model.newCode, sentTo: newEmail, confirmed: model.newConfirmed)

        UrButton(
            text: "Change email",
            action: {
                Task {
                    if await model.confirm() {
                        // the account's sign-in methods show the new email
                        _ = await networkUserViewModel?.refreshNetworkUser()
                    }
                }
            },
            enabled: model.canConfirm,
            isProcessing: model.isBusy
        )
    }

    /// One code's field, labeled with the address it went to; done (and
    /// checked) once the server accepted it.
    @ViewBuilder
    private func codeField(text: Binding<String>, sentTo: String, confirmed: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            #if os(iOS)
            UrTextField(
                text: text,
                label: "Code sent to \(sentTo)",
                placeholder: "",
                isEnabled: !confirmed && !model.isBusy,
                keyboardType: .numberPad,
                disableCapitalization: true,
                disableAutocorrection: true
            )
            #else
            UrTextField(
                text: text,
                label: "Code sent to \(sentTo)",
                placeholder: "",
                isEnabled: !confirmed && !model.isBusy,
                disableCapitalization: true,
                disableAutocorrection: true
            )
            #endif

            if confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.urGreen)
                    .accessibilityHidden(true)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func doneStep(email: String, otherSessionsSignedOut: Bool) -> some View {
        Text("Your email is now \(email).")
            .font(themeManager.currentTheme.bodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)

        if otherSessionsSignedOut {
            Text("Your other devices were signed out.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("To sign out your other devices, open Sessions.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }

        UrButton(
            text: "Done",
            action: {
                dismiss()
            }
        )
    }
}
