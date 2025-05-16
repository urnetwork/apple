//
//  CreateNetworkVerifyView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/27.
//
// OTP text field pulled from https://www.youtube.com/watch?v=E5LdH1MFrqQ
//

import SwiftUI
import URnetworkSdk

struct CreateNetworkVerifyView: View {
    
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var deviceManager: DeviceManager
    @StateObject private var viewModel: ViewModel
    
    // Keyboard state
    @FocusState private var isKeyboardShowing: Bool
    
    var backToRoot: () -> Void
    var handleSuccess: (_ jwt: String) async -> Void
    
    var isEmail: Bool = true
    
    init(
        userAuth: String,
        api: SdkApi,
        backToRoot: @escaping () -> Void,
        handleSuccess: @escaping (_ jwt: String) async -> Void
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(api: api, userAuth: userAuth))
        self.backToRoot = backToRoot
        self.handleSuccess = handleSuccess
        
        self.isEmail = userAuth.isEmail()
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            
            ScrollView(.vertical) {
                
                VStack {
                    
                    Text(isEmail ? "You've got mail" : "Check your phone")
                        .font(themeManager.currentTheme.titleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer().frame(height: 32)
                    
                    Text("Tell us who you really are. Enter the code we sent you to verify your identity.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    
                    Spacer().frame(height: 40)
                    
                    // OTP Text field
                    
                    HStack(spacing: 0) {
                        ForEach(0..<viewModel.codeCount, id: \.self) { index in
                            OTPTextBox(index)
                        }
                    }.background {
                        // hidden textfield which holds the otp value
                        
                        #if os(iOS)
                        TextField("", text: $viewModel.otp)
                            .onChange(of: viewModel.otp) { newValue in
                                
                                if newValue.count > viewModel.codeCount {
                                    viewModel.otp = String(newValue.prefix(viewModel.codeCount))
                                }
                                
                                if viewModel.otp.count == viewModel.codeCount && !viewModel.isSubmitting {
                                    
                                    Task {
                                        let result = await viewModel.submit()
                                        await self.handleOptSubmitResult(result)
                                    }
                                }
                                
                            }
                            .keyboardType(.numberPad)
                            .frame(width: 1, height: 1)
                            .opacity(0.001)
                            .blendMode(.screen)
                            .focused($isKeyboardShowing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textContentType(.oneTimeCode)
                        
                        #elseif os(macOS)
                    
                        TextField("", text: $viewModel.otp)
                            .onChange(of: viewModel.otp) { newValue in
                                
                                if newValue.count > viewModel.codeCount {
                                    viewModel.otp = String(newValue.prefix(viewModel.codeCount))
                                }
                                
                                if viewModel.otp.count == viewModel.codeCount && !viewModel.isSubmitting {
                                    
                                    Task {
                                        let result = await viewModel.submit()
                                        await self.handleOptSubmitResult(result)
                                    }
                                }
                                
                            }
                            .frame(width: 1, height: 1)
                            .opacity(0.001)
                            .blendMode(.screen)
                            .focused($isKeyboardShowing)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                    
                        #endif
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isKeyboardShowing.toggle()
                    }
                    
                    Spacer().frame(height: 40)
                    
                    HStack {
                     
                        Text("Don't see it? ", comment: "Referring to the OTP code")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                        
                        
                        Button(action: {
                            Task {
                                let result = await viewModel.resendOtp()
                                
                                switch result {
                                case .success:
                                    snackbarManager.showSnackbar(message: "Verification code sent.")
                                    break
                                case .failure(let error):
                                    print("error resending OTP \(error.localizedDescription)")
                                    
                                    snackbarManager.showSnackbar(message: "There was an error sending the verification code.")
                                    
                                    break
                                    
                                }
                            }
                        }) {
                            Text("Resend code")
                                .foregroundColor(themeManager.currentTheme.textColor)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                        }
                        
                    }
                    
                }
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            // path = NavigationPath() // Reset to root
                            backToRoot()
                        }) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                    }
                    #elseif os(macOS)
                    ToolbarItem {
                        Button(action: {
                            // path = NavigationPath() // Reset to root
                            backToRoot()
                        }) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                    }
                    #endif
                }
                .navigationBarBackButtonHidden(true)
                .padding()
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
            }
        }
        
    }
    
    private func handleOptSubmitResult(_ result: Result<String, Error>) async {
        
        switch result {
            
        case .success(let jwt):
            // consider launching this in a task
            // the ContentView will switch the the main app view before this function has completed
            
            #if canImport(UIKit)
            hideKeyboard()
            #endif
            
            await handleSuccess(jwt)
            // TODO: clear viewmodel loading state
            break
         
        case .failure(let error):
            print("[CreateNetworkVerifyView] handleOptSubmitResult: \(error.localizedDescription)")
            
            snackbarManager.showSnackbar(message: "There was an error authenticating, please try again later.")
            
            // TODO: clear viewmodel loading state
            
        }
        
    }
    
    @ViewBuilder
    func OTPTextBox(_ index: Int) -> some View {
        ZStack {
            if viewModel.otp.count > index {
                let startIndex = viewModel.otp.startIndex
                let charIndex = viewModel.otp.index(startIndex, offsetBy: index)
                let charToString = String(viewModel.otp[charIndex])
                Text(charToString)
                    .font(Font.custom("PPNeueBit-Bold", size: 24))
            } else {
                Text(" ")
            }
        }
        .frame(width: 38, height: 38)
        .background {
            
            // let isFocused = (isKeyboardShowing && index == viewModel.opt.count - 1)
            let isFocused = (isKeyboardShowing && index == viewModel.otp.count)
            
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isFocused ? themeManager.currentTheme.accentColor : themeManager.currentTheme.textFaintColor,
                    lineWidth: isFocused ? 1 : 0.5
                )
                .animation(.easeInOut(duration: 0.2), value: isFocused)
        }
        .frame(maxWidth: .infinity)
    }
    
}

#Preview {
    ZStack {
        CreateNetworkVerifyView(
            userAuth: "",
            api: SdkApi(),
            backToRoot: {},
            handleSuccess: {_ in }
        )
    }
    .environmentObject(ThemeManager.shared)
    .background(ThemeManager.shared.currentTheme.backgroundColor)
}
