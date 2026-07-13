//
//  LoginInitialView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/20.
//

import SwiftUI
import URnetworkSdk
import AuthenticationServices
import GoogleSignInSwift
import GoogleSignIn

struct LoginInitialView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @StateObject private var viewModel: ViewModel
    @State private var initialIsLandscape: Bool = false
    
    @ObservedObject var guestUpgradeViewModel: GuestUpgradeViewModel
    
    let navigate: (LoginInitialNavigationPath) -> Void
    let cancel: (() -> Void)?
    let handleSuccess: (_ jwt: String) async -> Void
    let urApiService: UrApiServiceProtocol
    
    init(
        urApiService: UrApiServiceProtocol,
        navigate: @escaping (LoginInitialNavigationPath) -> Void,
        cancel: (() -> Void)? = nil,
        handleSuccess: @escaping (_ jwt: String) async -> Void,
        guestUpgradeViewModel: GuestUpgradeViewModel
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(urApiService: urApiService))
        self.navigate = navigate
        self.cancel = cancel
        self.handleSuccess = handleSuccess
        self.guestUpgradeViewModel = guestUpgradeViewModel
        self.urApiService = urApiService
    }
    
    var body: some View {
        
        let deviceExists = deviceManager.device != nil
        
        GeometryReader { geometry in
            
            #if os(iOS)
            let isTablet = UIDevice.current.userInterfaceIdiom == .pad
            #else
            let isTablet = false
            #endif
      
            ScrollView {
                
                if initialIsLandscape && isTablet {
                    
                    HStack(alignment: .center) {
                        
                        LoginCarousel()
                            .frame(width: geometry.size.width / 2)
                        
                        LoginInitialFormView(
                            userAuth: $viewModel.userAuth,
                            handleUserAuth: handleUserAuth,
                            handleAppleLoginResult: handleAppleLoginResult,
                            handleGoogleSignInButton: handleGoogleSignInButton,
                            isValidUserAuth: viewModel.isValidUserAuth,
                            activeLoginAction: viewModel.activeLoginAction,
                            isLoginActionInFlight: viewModel.isLoginActionInFlight || guestUpgradeViewModel.isUpgrading,
                            loginErrorMessage: viewModel.loginErrorMessage,
                            deviceExists: deviceExists,
                            presentSignInWithSolanaSheet: {
                                viewModel.setPresentSigninWithSolanaSheet(true)
                            },
                            signInWithBittensor: {
                                handleBittensorSignIn()
                            },
                            presentAuthCodeLoginSheet: {
                                viewModel.setPresentAuthCodeLoginSheet(true)
                            },
                            presentGuestNetworkSheet: $viewModel.presentGuestNetworkSheet,
                        )
                        .frame(width: geometry.size.width / 2, alignment: .leading)
                        
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center) // Fill the height and center content
                    
                } else {
                
                    VStack {
                        
                        LoginCarousel()
                        
                        Spacer().frame(height: 64)
                        
                        LoginInitialFormView(
                            userAuth: $viewModel.userAuth,
                            handleUserAuth: handleUserAuth,
                            handleAppleLoginResult: handleAppleLoginResult,
                            handleGoogleSignInButton: handleGoogleSignInButton,
                            isValidUserAuth: viewModel.isValidUserAuth,
                            activeLoginAction: viewModel.activeLoginAction,
                            isLoginActionInFlight: viewModel.isLoginActionInFlight || guestUpgradeViewModel.isUpgrading,
                            loginErrorMessage: viewModel.loginErrorMessage,
                            deviceExists: deviceExists,
                            presentSignInWithSolanaSheet: {
                                viewModel.setPresentSigninWithSolanaSheet(true)
                            },
                            signInWithBittensor: {
                                handleBittensorSignIn()
                            },
                            presentAuthCodeLoginSheet: {
                                viewModel.setPresentAuthCodeLoginSheet(true)
                            },
                            presentGuestNetworkSheet: $viewModel.presentGuestNetworkSheet
                        )
                        
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                    
                }
                
            }
            .sheet(isPresented: $viewModel.presentSigninWithSolanaSheet) {
                
                SolanaSignMessageSheet(
                    isSigningMessage: viewModel.isSigningMessage,
                    setIsSigningMessage: viewModel.setIsSigningMessage,
                    signButtonText: "Sign in with Solana",
                    signButtonLabelText: "Sign in",
                    message: connectWalletProviderViewModel.welcomeMessage,
                    dismiss: {
                        viewModel.setPresentSigninWithSolanaSheet(false)
                    }
                )
                .environmentObject(themeManager)
                .environmentObject(connectWalletProviderViewModel)
                #if os(iOS)
                .presentationDetents([.height(216)])
                #endif
                
            }
            .sheet(isPresented: $viewModel.presentGuestNetworkSheet) {
                
                GuestModeSheet(
                    termsAgreed: $viewModel.termsAgreed,
                    isCreatingGuestNetwork: viewModel.isCreatingGuestNetwork,
                    errorMessage: viewModel.guestNetworkErrorMessage,
                    onCreateGuestNetwork: {
                        Task {
                            let result = await viewModel.createGuestNetwork()
                            await self.handleCreateGuestNetworkResult(result)
                        }
                    }
                )
                .environmentObject(themeManager)
                .presentationDetents([.height(264)])
                
            }
            .sheet(isPresented: $viewModel.presentAuthCodeLoginSheet) {
                
                AuthCodeLoginSheet(
                    urApiService: self.urApiService,
                    onSuccess: { jwt in
                        viewModel.setPresentAuthCodeLoginSheet(false)
                        Task {
                            await self.handleSuccess(jwt)
                        }
                    }
                )
                .environmentObject(themeManager)
                .presentationDetents([.height(264)])
                
            }
            .scrollIndicators(.hidden)
            .toolbar {
                if let cancel = cancel {
                    
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        
                        Button(action: { cancel() }) {
                            Image(systemName: "xmark")
                        }
                        
                    }
                    #elseif os(macOS)
                    ToolbarItem {
                        
                        Button(action: { cancel() }) {
                            Image(systemName: "xmark")
                        }
                        
                    }
                    #endif
                    
                    ToolbarItem(placement: .principal) {
                        Text("Create Account")
                            .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                    }
                }
            }
        }
        .onAppear {
            // Cache initial orientation
            #if os(iOS)
            let orientation = UIDevice.current.orientation
            initialIsLandscape = orientation.isLandscape
            #elseif os(macOS)
            initialIsLandscape = true
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Only update on actual rotation events
            let orientation = UIDevice.current.orientation
            if orientation.isValidInterfaceOrientation {
                initialIsLandscape = orientation.isLandscape
            }
        }
        #endif
        .onOpenURL { url in
            connectWalletProviderViewModel
                .handleDeepLink(
                    url,
                    onSignature: { signature in

                        guard let pk = connectWalletProviderViewModel.connectedPublicKey else {
                            viewModel.setIsSigningMessage(false)
                            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
                            return
                        }

                        Task {
                            if connectWalletProviderViewModel.connectedWalletProvider == .bittensor {
                                await handleBittensorWalletResult(
                                    message: connectWalletProviderViewModel.welcomeMessage,
                                    signature: signature,
                                    publicKey: pk
                                )
                            } else {
                                await handleSolanaWalletResult(
                                    message: connectWalletProviderViewModel.welcomeMessage,
                                    signature: signature,
                                    publicKey: pk
                                )
                            }
                        }

                    },
                    onError: { _ in
                        viewModel.setIsSigningMessage(false)
                        viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
                    }
                )
        }
        
    }
    
    private func handleSolanaWalletResult(message: String, signature: String, publicKey: String) async {
        print("handleSolanaWalletResult")
        
        guard viewModel.beginLoginAction(.solana) else {
            return
        }
        
        defer {
            viewModel.endLoginAction(.solana)
        }
        
        let createArgsResult = viewModel.createSolanaAuthLoginArgs(message: message, signature: signature, publicKey: publicKey)
        switch createArgsResult {
        case .success(let args):
            
            if deviceManager.device != nil {
                
                let upgradeArgs = self.createUpgradeSolanaWalletArgs(args)
                
                let result = await guestUpgradeViewModel.linkGuestToExistingLogin(args: upgradeArgs)
                
                await self.handleAuthLoginResult(result)
                viewModel.presentSigninWithSolanaSheet = false
                viewModel.setIsSigningMessage(false)
                
                
            } else {
                let result = await viewModel.authLogin(args: args)
                await self.handleAuthLoginResult(result)
                viewModel.presentSigninWithSolanaSheet = false
                viewModel.setIsSigningMessage(false)
            }
        
        case .failure(let error):
            print("error create args result: \(error.localizedDescription)")
            viewModel.setIsSigningMessage(false)
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
        }
    }
    
    private func handleCreateGuestNetworkResult(_ result: LoginNetworkResult) async {
        switch result {
            
        case .successWithJwt(let jwt):
            viewModel.presentGuestNetworkSheet = false
            await handleSuccess(jwt)
            break
        case .failure(let error):
            print("CreateNetworkView: handleResult: \(error.localizedDescription)")
            viewModel.setGuestNetworkErrorMessage("There was an error creating your guest network. Please try again.")
            break
        default:
            print("neither success with jwt or failure")
            viewModel.setGuestNetworkErrorMessage("There was an error creating your guest network. Please try again.")
            break
            
        }
    }
    
    private func handleAppleLoginResult(_ result: Result<ASAuthorization, any Error>) async {
        
        guard viewModel.beginLoginAction(.apple) else {
            return
        }
        
        defer {
            viewModel.endLoginAction(.apple)
        }

        let createArgsResult = viewModel.createAppleAuthLoginArgs(result)
        switch createArgsResult {
        case .success(let args):
            
            if deviceManager.device != nil {
        
                // device exists, meaning we're in the guest flow
                // link guest account to google account
                
                let upgradeArgs = self.createUpgradeExistingSocialArgs(args)
                
                let result = await guestUpgradeViewModel.linkGuestToExistingLogin(args: upgradeArgs)
                await self.handleAuthLoginResult(result)
                
            } else {
             
                // login with apple
                // let result = await viewModel.authLogin(args: args)
                let result = await viewModel.authLogin(args: args)
                await self.handleAuthLoginResult(result)
                
            }
        
        case .failure(let error):
            print("error create args result: \(error.localizedDescription)")
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
        }
        
     }
    
    
    private func handleUserAuth() async {
        
        let createArgsResult = viewModel.getStarted()
        switch createArgsResult {
        case .success(let args):
            
            guard viewModel.beginLoginAction(.userAuth) else {
                return
            }
            
            defer {
                viewModel.endLoginAction(.userAuth)
            }
            
            let result = await viewModel.authLogin(args: args)
            await self.handleAuthLoginResult(result)
        
        case .failure(let error):
            print("error create args result: \(error.localizedDescription)")
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
        }
        
    }
    
    private func handleAuthLoginResult(_ authLoginResult: AuthLoginResult) async {
        
        switch authLoginResult {
            
        case .login(let authJwt):
            await handleSuccess(authJwt)
            break
            
        case .promptPassword(let loginResult):
            viewModel.setIsCheckingUserAuth(false)
            navigate(.password(loginResult.userAuth))
            break

        case .create(let authLoginArgs):
            viewModel.setIsCheckingUserAuth(false)
            navigate(.createNetwork(authLoginArgs))
            break

        case .verificationRequired(let userAuth):
            viewModel.setIsCheckingUserAuth(false)
            navigate(.verify(userAuth))
            break

        case .incorrectAuth(let authAllowedErr):
            viewModel.setIsCheckingUserAuth(false)
            viewModel.setLoginErrorMessage(authAllowedErr)
            // in the guest-upgrade flow this view is presented as a sheet over the
            // app, where the inline error can be obscured — also surface a snackbar
            // (device is non-nil only during guest upgrade, nil for initial login)
            if deviceManager.device != nil {
                snackbarManager.showSnackbar(message: authAllowedErr)
            }
            break

        case .failure(let error):
            print("auth login error: \(error.localizedDescription)")
            viewModel.setIsCheckingUserAuth(false)
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
            if deviceManager.device != nil {
                snackbarManager.showSnackbar(message: String(localized: "There was an error logging in"))
            }
            break
            
        }
    }
    
    private func createUpgradeSolanaWalletArgs(_ args: SdkAuthLoginArgs) -> SdkUpgradeGuestExistingArgs {
        let updateArgs = SdkUpgradeGuestExistingArgs()
        updateArgs.walletAuth = args.walletAuth
        return updateArgs
    }

    /**
     * Bittensor sign in: opens the ur.io/wallet-connect bridge; the wallet
     * returns through onOpenURL with the ss58 address and sr25519 signature
     */
    private func handleBittensorSignIn() {
        connectWalletProviderViewModel.openBittensorSignIn(
            message: connectWalletProviderViewModel.welcomeMessage
        )
    }

    private func handleBittensorWalletResult(message: String, signature: String, publicKey: String) async {

        guard viewModel.beginLoginAction(.bittensor) else {
            return
        }

        defer {
            viewModel.endLoginAction(.bittensor)
        }

        let createArgsResult = viewModel.createBittensorAuthLoginArgs(message: message, signature: signature, publicKey: publicKey)
        switch createArgsResult {
        case .success(let args):

            if deviceManager.device != nil {

                let upgradeArgs = self.createUpgradeSolanaWalletArgs(args)

                let result = await guestUpgradeViewModel.linkGuestToExistingLogin(args: upgradeArgs)

                await self.handleAuthLoginResult(result)
                viewModel.setIsSigningMessage(false)

            } else {
                let result = await viewModel.authLogin(args: args)
                await self.handleAuthLoginResult(result)
                viewModel.setIsSigningMessage(false)
            }

        case .failure(let error):
            print("error create args result: \(error.localizedDescription)")
            viewModel.setIsSigningMessage(false)
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
        }
    }
    
    private func createUpgradeExistingSocialArgs(_ args: SdkAuthLoginArgs) -> SdkUpgradeGuestExistingArgs {
        let updateArgs = SdkUpgradeGuestExistingArgs()
        updateArgs.authJwt = args.authJwt
        updateArgs.authJwtType = args.authJwtType
        return updateArgs
    }
    
    private func handleGoogleSignInButton() async {
        
        guard viewModel.beginLoginAction(.google) else {
            return
        }
        
        defer {
            viewModel.endLoginAction(.google)
        }
        
        do {
            #if os(iOS)
            
            guard let rootViewController = getRootViewController() else {
                print("no root view controller found")
                viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
                return
            }
            
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            #elseif os(macOS)
            
            guard let presentingWindow = NSApplication.shared.windows.first else {
              print("There is no presenting window!")
              viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
              return
            }
            
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingWindow)
            #endif
            
            let createArgsResult = viewModel.createGoogleAuthLoginArgs(signInResult)
            switch createArgsResult {
            case .success(let args):
                
                if deviceManager.device != nil {
            
                    // device exists, meaning we're in the guest flow
                    // link guest account to google account
                    // let result = await viewModel.linkGuestToExistingSocialLogin(args: args)
                    
                    let upgradeArgs = self.createUpgradeExistingSocialArgs(args)
                    
                    let result = await guestUpgradeViewModel.linkGuestToExistingLogin(args: upgradeArgs)
                    
                    await self.handleAuthLoginResult(result)
                    
                } else {
                 
                    // login with google
                    let result = await viewModel.authLogin(args: args)
                    await self.handleAuthLoginResult(result)
                    
                }
            
            case .failure(let error):
                print("error create args result: \(error.localizedDescription)")
                viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
            }
            
         } catch {
             print("Error signing in: \(error.localizedDescription)")
             viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
         }
        
        
        
    }
    
}

private struct LoginInitialFormView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @Binding var userAuth: String
    let handleUserAuth: () async -> Void
    let handleAppleLoginResult: (_ result: Result<ASAuthorization, any Error>) async -> Void
    let handleGoogleSignInButton: () async -> Void
    let isValidUserAuth: Bool
    let activeLoginAction: LoginInitialView.LoginAction?
    let isLoginActionInFlight: Bool
    let loginErrorMessage: String?
    let deviceExists: Bool
    let presentSignInWithSolanaSheet: () -> Void
    let signInWithBittensor: () -> Void
    let presentAuthCodeLoginSheet: () -> Void

    @Binding var presentGuestNetworkSheet: Bool
    
    var body: some View {
        
        VStack {
         
            #if os(iOS)
            UrTextField(
                text: $userAuth,
                label: "Email or phone number",
                placeholder: "Enter your phone number or email",
                isEnabled: !isLoginActionInFlight,
                onTextChange: { newValue in
                    // Filter whitespace
                    if newValue.contains(" ") {
                        userAuth = newValue.filter { !$0.isWhitespace }
                    }
                },
                keyboardType: .emailAddress,
                submitLabel: .continue,
                onSubmit: {
                    if !isLoginActionInFlight {
                        Task {
                            await handleUserAuth()
                        }
                    }
                    
                }
            )
            #elseif os(macOS)
            UrTextField(
                text: $userAuth,
                label: "Email or phone number",
                placeholder: "Enter your phone number or email",
                isEnabled: !isLoginActionInFlight,
                onTextChange: { newValue in
                    // Filter whitespace
                    if newValue.contains(" ") {
                        userAuth = newValue.filter { !$0.isWhitespace }
                    }
                },
                submitLabel: .continue,
                onSubmit: {
                    if !isLoginActionInFlight {
                        Task {
                            await handleUserAuth()
                        }
                    }
                    
                }
            )
            #endif
            
            Spacer()
                .frame(height: 32)
            
            UrButton(
                text: "Get started",
                action: {
                    Task {
                        await handleUserAuth()
                    }
                },
                enabled: isValidUserAuth && !isLoginActionInFlight,
                isProcessing: activeLoginAction == .userAuth
            )
            
            Spacer()
                .frame(height: 24)
            
            Text("or", comment: "Referring to the two options 'Get started' *or* 'Login with Apple'")
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            
            Spacer()
                .frame(height: 24)
            
            SSOButtons(
                handleAppleLoginResult: handleAppleLoginResult,
                handleGoogleSignInButton: handleGoogleSignInButton,
                presentSignInWithSolanaSheet: presentSignInWithSolanaSheet,
                signInWithBittensor: signInWithBittensor,
                presentAuthCodeLoginSheet: presentAuthCodeLoginSheet,
                activeLoginAction: activeLoginAction,
                isLoginActionInFlight: isLoginActionInFlight
            )
            
            Spacer()
                .frame(height: 8)
            
            UrInlineErrorText(message: loginErrorMessage)
            
            Spacer()
                .frame(height: 24)
            
            if !deviceExists {
                // if a device exists, it means they are already in guest mode and trying to upgrade their account
                // restrict access to create guest network from within authed guest network

                HStack {
                    Text("Commitment issues?")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)

                    Button(action: {
                        presentGuestNetworkSheet = true
                    }) {
                        Text("Try Guest Mode")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoginActionInFlight)

                }

            }
            
        }
        .frame(maxWidth: 400)
    }
}

#if os(iOS)
private struct SSOButtons: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    
    let handleAppleLoginResult: (Result<ASAuthorization, Error>) async -> Void
    let handleGoogleSignInButton: () async -> Void
    let presentSignInWithSolanaSheet: () -> Void
    let signInWithBittensor: () -> Void
    let presentAuthCodeLoginSheet: () -> Void
    let activeLoginAction: LoginInitialView.LoginAction?
    let isLoginActionInFlight: Bool
    
    var body: some View {
        
        VStack {
        
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                Task {
                    await handleAppleLoginResult(result)
                }
            }
            .frame(height: 48)
            .clipShape(Capsule())
            .signInWithAppleButtonStyle(.white)
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if activeLoginAction == .apple {
                    ProgressView()
                        .tint(.urBlack)
                        .controlSize(.small)
                        .padding(.trailing, 16)
                }
            }
            .opacity(isLoginActionInFlight && activeLoginAction != .apple ? 0.3 : 1)
            .disabled(isLoginActionInFlight)
            .allowsHitTesting(!isLoginActionInFlight)
            
            Spacer()
                .frame(height: 24)
            
            UrGoogleSignInButton(
                action: handleGoogleSignInButton,
                enabled: !isLoginActionInFlight,
                isProcessing: activeLoginAction == .google
            )
            .buttonStyle(.plain)
            
            Spacer()
                .frame(height: 24)

            /**
             * Bittensor sign in runs through the ur.io/wallet-connect bridge,
             * so it does not depend on an installed wallet app
             */
            Button(action: signInWithBittensor) {
                ZStack {
                    HStack {
                        Text("τ")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            .font(
                                Font.system(size: 19, weight: .bold)
                            )
                        Spacer().frame(width: 8)
                        Text("Sign in with Bittensor")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            .font(
                                Font.system(size: 19, weight: .medium)
                            )
                    }

                    if activeLoginAction == .bittensor {
                        HStack {
                            Spacer()
                            ProgressView()
                                .tint(.urBlack)
                                .controlSize(.small)
                                .padding(.trailing, 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 48)
            .background(.white)
            .clipShape(Capsule())
            .buttonStyle(.plain)
            .opacity(isLoginActionInFlight && activeLoginAction != .bittensor ? 0.3 : 1)
            .disabled(isLoginActionInFlight)

            // check if either .phantom or solflare are installed
            if (connectWalletProviderViewModel.isWalletAppInstalled(.phantom)
                || connectWalletProviderViewModel.isWalletAppInstalled(.solflare)
            ) {

                Spacer()
                    .frame(height: 24)

                Button(action: presentSignInWithSolanaSheet) {
                    ZStack {
                        HStack {
                            Image("solana.gradient.logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16)
                            Spacer().frame(width: 8)
                            Text("Sign in with Solana")
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                .font(
                                    Font.system(size: 19, weight: .medium)
                                )
                        }
                        
                        if activeLoginAction == .solana {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .tint(.urBlack)
                                    .controlSize(.small)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 48)
                .background(.white)
                .clipShape(Capsule())
                .buttonStyle(.plain)
                .opacity(isLoginActionInFlight && activeLoginAction != .solana ? 0.3 : 1)
                .disabled(isLoginActionInFlight)
                
            }
            
            Spacer()
                .frame(height: 24)
            
            Button(action: presentAuthCodeLoginSheet) {
                HStack {
                    Image("ur.symbols.auth_code")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16)
                    Spacer().frame(width: 8)
                    Text("Log in with Auth Code")
                        .foregroundColor(themeManager.currentTheme.inverseTextColor)
                        .font(
                            Font.system(size: 19, weight: .medium)
                        )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 48)
            .background(.white)
            .clipShape(Capsule())
            .buttonStyle(.plain)
            .opacity(isLoginActionInFlight ? 0.3 : 1)
            .disabled(isLoginActionInFlight)
            
            Spacer()
                .frame(height: 24)
            
        }
        
    }
}
#elseif os(macOS)
private struct SSOButtons: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var handleAppleLoginResult: (Result<ASAuthorization, Error>) async -> Void
    var handleGoogleSignInButton: () async -> Void
    var presentSignInWithSolanaSheet: () -> Void
    var signInWithBittensor: () -> Void
    let presentAuthCodeLoginSheet: () -> Void
    let activeLoginAction: LoginInitialView.LoginAction?
    let isLoginActionInFlight: Bool
    
    var body: some View {
        
        VStack {
         
            HStack {
            
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    Task {
                        await handleAppleLoginResult(result)
                    }
                }
                .frame(maxWidth: .infinity)
                .signInWithAppleButtonStyle(.white)
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) {
                    if activeLoginAction == .apple {
                        ProgressView()
                            .tint(.urBlack)
                            .controlSize(.small)
                            .padding(.trailing, 12)
                    }
                }
                .opacity(isLoginActionInFlight && activeLoginAction != .apple ? 0.3 : 1)
                .disabled(isLoginActionInFlight)
                .allowsHitTesting(!isLoginActionInFlight)
                
                UrGoogleSignInButton(
                    action: handleGoogleSignInButton,
                    enabled: !isLoginActionInFlight,
                    isProcessing: activeLoginAction == .google
                )
                .buttonStyle(.plain)
                
            }
            
            Spacer()
                .frame(height: 8)
            
            HStack {
             
                Button(action: presentAuthCodeLoginSheet) {
                    HStack {
                        Image("ur.symbols.auth_code")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16)
                        Spacer().frame(width: 8)
                        Text("Log in with Auth Code")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            .font(
                                Font.system(size: 12, weight: .medium)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .background(.white)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .opacity(isLoginActionInFlight ? 0.3 : 1)
                .disabled(isLoginActionInFlight)
                
                // nudge to account for padding
                Spacer().frame(width: 8)

                // so button only takes up half space
                Spacer().frame(maxWidth: .infinity)
                
            }
            .frame(maxWidth: .infinity)
            
            Spacer()
                .frame(height: 8)

            HStack {
                /**
                 * Bittensor sign in, placed before Solana. Runs through the
                 * ur.io/wallet-connect bridge (browser extension wallets)
                 */
                Button(action: signInWithBittensor) {
                    HStack {
                        Text("τ")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            .font(
                                Font.system(size: 12, weight: .bold)
                            )
                        Spacer().frame(width: 8)
                        Text("Sign in with Bittensor")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                .font(
                                    Font.system(size: 12, weight: .medium)
                                )
                    }
                }
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .background(.white)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .disabled(isLoginActionInFlight)

                Spacer().frame(width: 8)

                Button(action: presentSignInWithSolanaSheet) {
                    HStack {
                        Image("solana.gradient.logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16)
                        Spacer().frame(width: 8)
                        Text("Sign in with Solana")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                .font(
                                    Font.system(size: 12, weight: .medium)
                                )
                    }
                }
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .background(.white)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .disabled(isLoginActionInFlight)
            }
            .frame(maxWidth: .infinity)
            
        }
        
    }
}
#endif


//#Preview {
//    ZStack {
//        LoginInitialView(
//            api: nil,
//            navigate: {_ in },
//            handleSuccess: {_ in },
//        )
//    }
//    .environmentObject(ThemeManager.shared)
//    .background(ThemeManager.shared.currentTheme.backgroundColor)
//}
