//
//  LoginPasswordView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import SwiftUI
import URnetworkSdk

struct LoginPasswordView: View {
    
    @Environment(\.networkLoginContext) private var loginContext
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel: ViewModel
    
    var userAuth: String
    var navigate: (LoginInitialNavigationPath) -> Void
    var handleSuccess: NetworkLoginCredentialHandler
    
    let snackbarErrorMessage = "There was an error authenticating. Please try again."
    
    init(
        userAuth: String,
        navigate: @escaping (LoginInitialNavigationPath) -> Void,
        handleSuccess: @escaping NetworkLoginCredentialHandler,
        api: SdkApi?
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(api: api))
        self.userAuth = userAuth
        self.navigate = navigate
        self.handleSuccess = handleSuccess
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack {
                    Text("It's nice to see you again")
                        .foregroundColor(.urWhite)
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 64)
                    
                    UrTextField(
                        text: .constant(userAuth),
                        label: "Email or phone number",
                        placeholder: "Enter your phone number or email",
                        isEnabled: false
                    )
                    
                    Spacer().frame(height: 16)
                    
                    UrTextField(
                        text: $viewModel.password,
                        label: "Password",
                        placeholder: "************",
                        isEnabled: !isLoginInProgress,
                        submitLabel: .continue,
                        onSubmit: {
                            if viewModel.isValid && !isLoginInProgress {
                                submitPasswordLogin()
                            }
                        },
                        isSecure: true,
                        accessibilityIdentifier: "acceptance.password.input"
                    )
                    
                    Spacer().frame(height: 32)
                    
                    UrButton(
                        text: "Continue",
                        action: {
                            
                            #if canImport(UIKit)
                            hideKeyboard()
                            #endif
                            
                            if viewModel.isValid && !isLoginInProgress {
                                submitPasswordLogin()
                            }
                        },
                        enabled: !isLoginInProgress && viewModel.isValid,
                        isProcessing: isLoginInProgress,
                        accessibilityIdentifier: "acceptance.password.submit"
                    )
                    
                    Spacer().frame(height: 8)
                    
                    UrInlineErrorText(message: viewModel.errorMessage)
                    
                    Spacer().frame(height: 32)
                    
                    HStack {
                        Text("Forgot your password?")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        
                        Button(action: {
                            navigate(.resetPassword(userAuth))
                        }) {
                            Text(
                                "Reset it.",
                                comment: "Referring to resetting the password"
                            )
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                        .disabled(isLoginInProgress)
                    }
                }
                .padding()
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
            }
        }
    
    }
    
    private var isLoginInProgress: Bool {
        viewModel.isLoggingIn
    }
    
    private func submitPasswordLogin() {
        if isLoginInProgress || !viewModel.isValid {
            return
        }
        
        guard let request = loginContext?.begin() else { return }
        viewModel.setErrorMessage(nil)
        Task {
            guard request.isCurrent else { return }
            let result = await viewModel.loginWithPassword(userAuth: self.userAuth, request: request)
            guard request.isCurrent else { return }
            await handleLoginResult(result, request: request)
        }
    }
    
    private func handleLoginResult(_ result: LoginNetworkResult, request: NetworkLoginRequest) async {
        switch result {
            
        case .successWithJwt(let jwt):
            await handleSuccess(jwt, request)
            break
            
        case .successWithVerificationRequired(let sendNotice):
            navigate(.verify(userAuth, sendNotice: sendNotice))
            viewModel.setIsLoggingIn(false)
            break
            
        case .failure(let error):
            print("LoginPasswordView: handleResult: \(error.localizedDescription)")
            
            viewModel.setIsLoggingIn(false)
            viewModel.setErrorMessage(snackbarErrorMessage)
            
            break
            
        }
    }
    
}

//#Preview {
//    
//    ZStack {
//    
//        LoginPasswordView(
//            userAuth: "hello@ur.io",
//            navigate: {_ in },
//            handleSuccess: {_ in },
//            api: nil
//        )
//        
//    }
//    .environmentObject(ThemeManager.shared)
//    .background(ThemeManager.shared.currentTheme.backgroundColor)
//    
//}
