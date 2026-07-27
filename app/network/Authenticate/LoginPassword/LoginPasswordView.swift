//
//  LoginPasswordView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import SwiftUI
import URnetworkSdk

struct LoginPasswordView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel: ViewModel
    
    var userAuth: String
    var navigate: (LoginInitialNavigationPath) -> Void
    var handleSuccess: (_ jwt: String) async -> Void
    
    let snackbarErrorMessage = "There was an error authenticating. Please try again."
    
    init(
        userAuth: String,
        navigate: @escaping (LoginInitialNavigationPath) -> Void,
        handleSuccess: @escaping (_ jwt: String) async -> Void,
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
                                Task {
                                    await submitPasswordLogin()
                                }
                            }
                        },
                        isSecure: true
                    )
                    
                    Spacer().frame(height: 32)
                    
                    UrButton(
                        text: "Continue",
                        action: {
                            
                            #if canImport(UIKit)
                            hideKeyboard()
                            #endif
                            
                            if viewModel.isValid && !isLoginInProgress {
                                Task {
                                    await submitPasswordLogin()
                                }
                            }
                        },
                        enabled: !isLoginInProgress && viewModel.isValid,
                        isProcessing: isLoginInProgress
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
    
    private func submitPasswordLogin() async {
        if isLoginInProgress || !viewModel.isValid {
            return
        }
        
        viewModel.setErrorMessage(nil)
        
        let result = await viewModel.loginWithPassword(userAuth: self.userAuth)
        await handleLoginResult(result)
    }
    
    private func handleLoginResult(_ result: LoginNetworkResult) async {
        switch result {
            
        case .successWithJwt(let jwt):
            await handleSuccess(jwt)
            break
            
        case .successWithVerificationRequired:
            navigate(.verify(userAuth))
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
