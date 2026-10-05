//
//  CreateNetworkView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import SwiftUI
import URnetworkSdk

struct CreateNetworkView: View {

    var authLoginArgs: SdkAuthLoginArgs
    var navigate: (LoginInitialNavigationPath) -> Void
    
    var userAuth: String?
    var authJwt: String?
    
    var handleSuccess: (_ jwt: String) async -> Void
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    @StateObject private var viewModel: ViewModel

    @FocusState private var focusedField: Field?
    
    init(
        authLoginArgs: SdkAuthLoginArgs,
        navigate: @escaping (LoginInitialNavigationPath) -> Void,
        handleSuccess: @escaping (_ jwt: String) async -> Void,
        api: SdkApi,
        urApiService: UrApiServiceProtocol
    ) {
        
        var authType: AuthType = .password
        
        if authLoginArgs.authJwtType == "apple" {
            authType = AuthType.apple
        }
        
        if authLoginArgs.authJwtType == "google" {
            authType = AuthType.google
        }
        
        if authLoginArgs.walletAuth != nil {
            authType = AuthType.solana
        }
        
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            api: api,
            urApiService: urApiService,
            authType: authType
        ))
        
        self.authLoginArgs = authLoginArgs
        
        if !authLoginArgs.userAuth.isEmpty {
            self.userAuth = authLoginArgs.userAuth
        } else {
            self.userAuth = nil
        }
        
        if authLoginArgs.authJwtType == "apple" && !authLoginArgs.authJwt.isEmpty {
            self.authJwt = authLoginArgs.authJwt
        } else {
            self.authJwt = nil
        }
        
        self.navigate = navigate
        self.handleSuccess = handleSuccess
    }

    enum Field {
        case networkName, password
    }
    
    var body: some View {

        GeometryReader { geometry in
            
            ScrollView(.vertical) {
                VStack(alignment: .center) {
                    Text("Join URnetwork", comment: "URnetwork is the project name and should not be translated")
                        .foregroundColor(.urWhite)
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 48)
                    
                    if let userAuth = userAuth {
                        
                        #if os(iOS)
                        UrTextField(
                            text: .constant(userAuth),
                            label: "Email or phone number",
                            placeholder: "Enter your phone number or email",
                            isEnabled: false,
                            keyboardType: .emailAddress,
                            submitLabel: .next
                        )
                        #elseif os(macOS)
                        UrTextField(
                            text: .constant(userAuth),
                            label: "Email or phone number",
                            placeholder: "Enter your phone number or email",
                            isEnabled: false,
                            submitLabel: .next
                        )
                        #endif
                        
                        Spacer().frame(height: 24)
                        
                    }
                    
                    UrTextField(
                        text: $viewModel.networkName,
                        label: "Network name",
                        placeholder: "Enter a name for your network",
                        supportingText: viewModel.networkNameSupportingText,
                        isEnabled: !viewModel.isCreatingNetwork,
                        validationState: viewModel.networkNameValidationState,
                        submitLabel: .next,
                        disableCapitalization: true,
                        accessibilityIdentifier: "acceptance.create.network"
                    )
                    .focused($focusedField, equals: .networkName)
                    .onSubmit {
                        
                        if (userAuth != nil) {
                            focusedField = .password
                        }
                        
                    }
                    
                    if (userAuth != nil) {
                        
                        Spacer().frame(height: 24)
                        
                        UrTextField(
                            text: $viewModel.password,
                            label: "Password",
                            placeholder: "************",
                            supportingText: "Password must be at least 12 characters long",
                            isEnabled: !viewModel.isCreatingNetwork,
                            submitLabel: .done,
                            isSecure: true,
                            accessibilityIdentifier: "acceptance.create.password"
                        )
                        .focused($focusedField, equals: .password)
                        
                    }
                    
                    Spacer().frame(height: 32)
                    
                    UrSwitchToggle(isOn: $viewModel.termsAgreed, isEnabled: !viewModel.isCreatingNetwork) {
                        Text("I agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                    }
                    .accessibilityIdentifier("acceptance.create.terms")

                    Spacer().frame(height: 16)

                    // the marketing opt-out shown at collection: on by default, one tap off
                    UrSwitchToggle(isOn: $viewModel.productUpdates, isEnabled: !viewModel.isCreatingNetwork) {
                        Text("Periodic product updates")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                    }
                    .accessibilityIdentifier("acceptance.create.productUpdates")
                    
                    Spacer().frame(height: 24)

                    // the optional referral code, always visible above
                    // Continue (the Windows sign-up's bonus code field)
                    ReferralCodeFieldView(
                        entry: viewModel.referralEntry,
                        isEnabled: !viewModel.isCreatingNetwork,
                        accessibilityIdentifier: "acceptance.create.referral"
                    )
                    
                    Spacer().frame(height: 24)
                    
                    UrButton(
                        text: "Continue",
                        action: {
                            
                            #if canImport(UIKit)
                            hideKeyboard()
                            #endif
                            
                            Task {
                                let result = await viewModel.createNetwork(
                                    userAuth: userAuth,
                                    authJwt: authLoginArgs.authJwt,
                                    authType: authLoginArgs.authJwtType,
                                    walletAuth: authLoginArgs.walletAuth
                                )
                                
                                await handleResult(result)
                            }
                            
                        },
                        enabled: viewModel.formIsValid && !viewModel.isCreatingNetwork,
                        isProcessing: viewModel.isCreatingNetwork,
                        accessibilityIdentifier: "acceptance.create.submit"
                    )
                    
                    Spacer().frame(height: 8)
                    
                    UrInlineErrorText(message: viewModel.createNetworkErrorMessage)
                    
                }
                .padding()
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    private func handleResult(_ result: LoginNetworkResult) async {
        print("CreateNetworkView handleResult")
        switch result {
            
        case .successWithJwt(let jwt):
            print("success with jwt: \(jwt)")
            await handleSuccess(jwt)
            break
        case .successWithVerificationRequired(let sendNotice):
            if let userAuth = userAuth {
                print("navigate to verify with userauth: \(userAuth)")
                navigate(.verify(userAuth, sendNotice: sendNotice))
            } else {
                print("CreateNetworkView: successWithVerificationRequired: userAuth is nil")
            }
            break
        case .failure(let error):
            print("CreateNetworkView: handleResult: \(error.localizedDescription)")
            viewModel.setCreateNetworkErrorMessage(createNetworkFailureMessage(error))
            break
            
        }
    }
    
}

//#Preview {
//    ZStack {
//        CreateNetworkView(
//            authLoginArgs: SdkAuthLoginArgs(),
//            navigate: {_ in },
//            handleSuccess: {_ in },
//            api: SdkApi()
//        )
//    }
//    .environmentObject(ThemeManager.shared)
//    .background(ThemeManager.shared.currentTheme.backgroundColor)
//}
