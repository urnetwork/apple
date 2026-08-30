//
//  CreateNetworkInstantView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

private struct InstantAccountResult: Identifiable {
    let id = UUID()
    let jwt: String
    let seedphrase: String
}

struct CreateNetworkInstantView: View {

    @EnvironmentObject var themeManager: ThemeManager

    @StateObject private var viewModel: ViewModel

    let handleSuccess: (_ jwt: String) async -> Void
    let back: () -> Void

    @State private var accountResult: InstantAccountResult? = nil

    // flips to true when the referral code is accepted; the bonus sheet shows
    // the gold royal welcome for a beat before dismissing itself
    @State private var showRoyalWelcome = false

    init(
        urApiService: UrApiServiceProtocol,
        handleSuccess: @escaping (_ jwt: String) async -> Void,
        back: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(urApiService: urApiService))
        self.handleSuccess = handleSuccess
        self.back = back
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center) {

                Text("Create Instant Account")
                    .foregroundColor(.urWhite)
                    .font(themeManager.currentTheme.titleFont)

                Spacer().frame(height: 16)

                Text("No email, phone, or password needed. Your account is secured by a seedphrase.")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .font(themeManager.currentTheme.bodyFont)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 48)

                UrSwitchToggle(isOn: $viewModel.termsAgreed, isEnabled: !viewModel.isCreatingAccount) {
                    Text("I agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                }
                .accessibilityIdentifier("acceptance.instant.terms")

                Spacer().frame(height: 16)

                if viewModel.isValidReferralCode && !viewModel.isCappedReferralCode {

                    ReferralAppliedChip()

                    Spacer().frame(height: 16)
                }

                Spacer().frame(height: 16)

                UrButton(
                    text: "Create Account",
                    action: {
                        Task {
                            let result = await viewModel.createInstantAccount()
                            if let (jwt, seedphrase) = result {
                                accountResult = InstantAccountResult(jwt: jwt, seedphrase: seedphrase)
                            }
                        }
                    },
                    enabled: viewModel.formIsValid,
                    isProcessing: viewModel.isCreatingAccount,
                    accessibilityIdentifier: "acceptance.instant.create"
                )

                Spacer().frame(height: 8)

                UrInlineErrorText(message: viewModel.errorMessage)

                Spacer().frame(height: 32)

                Button(action: {
                    viewModel.isPresentedAddBonusSheet = true
                }) {
                    Text((!viewModel.bonusReferralCode.isEmpty) ? "Edit referral code" : "Add referral code")
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                        .font(themeManager.currentTheme.toolbarTitleFont.bold())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCreatingAccount)

            }
            .padding()
            .frame(maxWidth: .infinity)
            .frame(maxWidth: 400)
        }
        .sheet(isPresented: $viewModel.isPresentedAddBonusSheet, onDismiss: {
            showRoyalWelcome = false
        }) {

            VStack {

                if showRoyalWelcome {

                    // the code was accepted: show the gold royal welcome
                    // for a beat before dismissing the sheet
                    RoyalWelcomeContent()

                } else {

                    HStack {
                        Text("Add referral code to earn extra rewards")
                            .font(themeManager.currentTheme.toolbarTitleFont)

                        Spacer()
                    }

                    Spacer().frame(height: 32)

                    UrTextField(
                        text: $viewModel.bonusReferralCode,
                        label: "Bonus referral code",
                        placeholder: "Enter a bonus referral code",
                        supportingText: viewModel.referralCodeInputSupportingText,
                        isEnabled: !viewModel.isValidatingReferralCode,
                        submitLabel: .done,
                        onSubmit: {
                            Task {
                                let result = await viewModel.validateReferralCode()
                                self.handleValidateReferralResult(result)
                            }
                        }
                    )

                    Spacer().frame(height: 32)

                    UrButton(
                        text: "Apply bonus",
                        action: {
                            Task {
                                let result = await viewModel.validateReferralCode()
                                self.handleValidateReferralResult(result)
                            }
                        },
                        enabled: !viewModel.isValidatingReferralCode && !viewModel.bonusReferralCode.isEmpty,
                        isProcessing: viewModel.isValidatingReferralCode
                    )

                }

            }
            .padding()
            .presentationDetents([.height(showRoyalWelcome ? 420 : 264)])
            .environmentObject(themeManager)

        }
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { back() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
            }
            #elseif os(macOS)
            ToolbarItem {
                Button(action: { back() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
            }
            #endif
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .fullScreenCover(item: $accountResult) { result in
            SeedphraseDisplayView(
                seedphrase: result.seedphrase,
                onConfirmed: { _ in
                    accountResult = nil
                    Task {
                        await handleSuccess(result.jwt)
                    }
                }
            )
            .environmentObject(themeManager)
        }
        #elseif os(macOS)
        .sheet(item: $accountResult) { result in
            SeedphraseDisplayView(
                seedphrase: result.seedphrase,
                onConfirmed: { _ in
                    accountResult = nil
                    Task {
                        await handleSuccess(result.jwt)
                    }
                }
            )
            .environmentObject(themeManager)
            .interactiveDismissDisabled(true)
        }
        #endif
    }

    private func handleValidateReferralResult(_ result: Result<SdkValidateReferralCodeResult, Error>) {

        switch result {
            case .success(let validationResult):
            if (validationResult.isValid && !validationResult.isCapped) {
                // royal welcome moment, then dismiss the sheet
                withAnimation {
                    showRoyalWelcome = true
                }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    viewModel.isPresentedAddBonusSheet = false
                    showRoyalWelcome = false
                }
            }

            case .failure(let error):
                print("validate referral code error: \(error.localizedDescription)")

        }

    }

}
