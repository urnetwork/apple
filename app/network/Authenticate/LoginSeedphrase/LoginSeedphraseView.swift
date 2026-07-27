//
//  LoginSeedphraseView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

struct LoginSeedphraseView: View {

    @EnvironmentObject var themeManager: ThemeManager

    @StateObject private var viewModel: ViewModel

    let handleSuccess: (_ jwt: String) async -> Void
    let back: () -> Void

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

                Text("Sign in with Seedphrase")
                    .foregroundColor(.urWhite)
                    .font(themeManager.currentTheme.titleFont)

                Spacer().frame(height: 48)

                TextEditor(text: $viewModel.seedphrase)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.textMutedColor.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if viewModel.seedphrase.isEmpty {
                            Text("Paste your 24-word seedphrase here")
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .font(themeManager.currentTheme.bodyFont)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .cornerRadius(8)

                Spacer().frame(height: 32)

                UrButton(
                    text: "Sign In",
                    action: {
                        Task {
                            let result = await viewModel.login()
                            await handleResult(result)
                        }
                    },
                    enabled: viewModel.isSeedphraseValid && !viewModel.isLoggingIn,
                    isProcessing: viewModel.isLoggingIn
                )

                Spacer().frame(height: 8)

                if let wordCountWarning = viewModel.wordCountWarning {
                    Text(wordCountWarning)
                        .foregroundColor(.urYellow)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Spacer().frame(height: 8)
                }

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
        #endif
    }

    private func handleResult(_ result: AuthLoginResult) async {
        switch result {
        case .login(let jwt):
            await handleSuccess(jwt)
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        default:
            viewModel.errorMessage = "There was an error signing in with your seedphrase. Please try again."
        }
    }

}
