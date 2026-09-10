//
//  LoginAuthCodeView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * Sign in with a one-time auth code, pushed onto the login stack like the
 * seedphrase sign-in: title, the code field, the launch button, and a back
 * chevron in the toolbar.
 */
struct LoginAuthCodeView: View {

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

                Text("Auth code login")
                    .foregroundColor(.urWhite)
                    .font(themeManager.currentTheme.titleFont)

                Spacer().frame(height: 48)

                UrTextField(
                    text: $viewModel.authCode,
                    label: "Authentication code",
                    placeholder: "Enter your one-time auth code",
                    supportingText: viewModel.loginFailed ? "There was an error validating your auth code. Please try again or generate a new one" : "",
                    isEnabled: !viewModel.isLoading,
                    validationState: viewModel.loginFailed ? .invalid : .valid,
                    submitLabel: .done,
                    onSubmit: {
                        submit()
                    },
                    isSecure: true
                )

                Spacer().frame(height: 32)

                UrButton(
                    text: "Launch",
                    action: {
                        submit()
                    },
                    enabled: !viewModel.authCode.isEmpty && !viewModel.isLoading,
                    isProcessing: viewModel.isLoading
                )

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

    private func submit() {
        guard !viewModel.isLoading, !viewModel.authCode.isEmpty else { return }
        Task {
            let result = await viewModel.authCodeLogin()
            await handleResult(result)
        }
    }

    @MainActor
    private func handleResult(_ result: Result<SdkAuthCodeLoginResult, Error>) async {
        switch result {
        case .success(let authCodeLoginResult):
            await handleSuccess(authCodeLoginResult.jwt)
        case .failure:
            // the view model flags the field; nothing else to show
            break
        }
    }

}

#Preview {
    LoginAuthCodeView(
        urApiService: MockUrApiService(),
        handleSuccess: { _ in },
        back: {}
    )
    .environmentObject(ThemeManager.shared)
}
