//
//  ResetPasswordView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/07.
//

import SwiftUI
import URnetworkSdk

struct ResetPasswordView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    
    @StateObject private var viewModel: ViewModel
    
    var userAuth: String
    var popNavigationStack: () -> Void
    
    // counts a rate limit down
    private let cooldownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    init(
        userAuth: String,
        popNavigationStack: @escaping () -> Void,
        api: SdkApi
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(api: api))
        self.userAuth = userAuth
        self.popNavigationStack = popNavigationStack
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack {
                    Text("Forgot your password?")
                        .foregroundColor(.urWhite)
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 64)
                    
                    UrTextField(
                        text: .constant(userAuth),
                        label: "Email or phone number",
                        placeholder: "Enter your phone number or email",
                        isEnabled: false
                    )
                    
                    Spacer().frame(height: 8)
                    
                    HStack {
                        Text("You may need to your check spam folder or unblock no-reply@ur.io")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        Spacer()
                    }
                    
                    Spacer().frame(height: 24)
                    
                    UrButton(
                        text: "Send reset link",
                        action: {
                            Task {
                                await handleResendLink()
                            }
                        },
                        enabled: viewModel.sendEnabled,
                        isProcessing: viewModel.sendInProgress
                    )
                    
                    Spacer().frame(height: 8)
                    
                    UrInlineErrorText(message: viewModel.errorMessage)
                }
                .onReceive(cooldownTimer) { _ in
                    viewModel.tick()
                }
                .padding()
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    private func handleResendLink() async {
        
        let result = await viewModel.sendResetLink(userAuth)
        
        switch result {
            
        case .success(let notice):
            
            // a link that was not sent is shown as the view model's error message
            guard notice == .sent else {
                break
            }
            
            snackbarManager.showSnackbar(message: String(localized: "Password reset link sent to \(userAuth)."))
            
            self.popNavigationStack()
            break
            
        case .failure(let error):
            print("error sending reset link: \(error.localizedDescription)")
            viewModel.setErrorMessage("There was an error sending a password reset link to \(userAuth).")
            
            break
        }
        
    }
}

#Preview {
    ZStack {
        ResetPasswordView(
            userAuth: "hello@ur.io",
            popNavigationStack: {},
            api: SdkApi()
        )
    }
    .environmentObject(ThemeManager.shared)
    .background(ThemeManager.shared.currentTheme.backgroundColor)
}
