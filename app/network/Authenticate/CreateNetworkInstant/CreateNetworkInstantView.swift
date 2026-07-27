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

                Spacer().frame(height: 32)

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
                    isProcessing: viewModel.isCreatingAccount
                )

                Spacer().frame(height: 8)

                UrInlineErrorText(message: viewModel.errorMessage)

            }
            .padding()
            .frame(maxWidth: .infinity)
            .frame(maxWidth: 400)
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

}
