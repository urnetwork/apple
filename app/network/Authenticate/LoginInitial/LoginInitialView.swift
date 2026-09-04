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
    // the Solana tile without a wallet app to hand off to (iOS only)
    @State private var presentNoSolanaWalletAlert: Bool = false
    
    let navigate: (LoginInitialNavigationPath) -> Void
    let cancel: (() -> Void)?
    let handleSuccess: (_ jwt: String) async -> Void
    let urApiService: UrApiServiceProtocol
    
    init(
        urApiService: UrApiServiceProtocol,
        navigate: @escaping (LoginInitialNavigationPath) -> Void,
        cancel: (() -> Void)? = nil,
        handleSuccess: @escaping (_ jwt: String) async -> Void
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(urApiService: urApiService))
        self.navigate = navigate
        self.cancel = cancel
        self.handleSuccess = handleSuccess
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
                            isLoginActionInFlight: viewModel.isLoginActionInFlight,
                            loginErrorMessage: viewModel.loginErrorMessage,
                            deviceExists: deviceExists,
                            presentSignInWithSolanaSheet: {
                                startSolanaSignIn()
                            },
                            signInWithBittensor: {
                                handleBittensorSignIn()
                            },
                            presentAuthCodeLoginSheet: {
                                viewModel.setPresentAuthCodeLoginSheet(true)
                            },
                            presentSeedphraseLogin: {
                                navigate(.seedphrase)
                            },
                            presentCreateInstant: {
                                navigate(.createInstant)
                            }
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
                            isLoginActionInFlight: viewModel.isLoginActionInFlight,
                            loginErrorMessage: viewModel.loginErrorMessage,
                            deviceExists: deviceExists,
                            presentSignInWithSolanaSheet: {
                                startSolanaSignIn()
                            },
                            signInWithBittensor: {
                                handleBittensorSignIn()
                            },
                            presentAuthCodeLoginSheet: {
                                viewModel.setPresentAuthCodeLoginSheet(true)
                            },
                            presentSeedphraseLogin: {
                                navigate(.seedphrase)
                            },
                            presentCreateInstant: {
                                navigate(.createInstant)
                            }
                        )
                        
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                    
                }
                
            }
            .alert(String(localized: "No Solana Wallets Found"), isPresented: $presentNoSolanaWalletAlert) {
                Button(String(localized: "Got it")) {}
            } message: {
                Text("No Solana wallets were found installed on this device. Please install a wallet and try again.")
            }
            .sheet(isPresented: $viewModel.presentSigninWithSolanaSheet) {
                
                SolanaSignMessageSheet(
                    isSigningMessage: viewModel.isSigningMessage,
                    setIsSigningMessage: viewModel.setIsSigningMessage,
                    signButtonText: "Sign in with Solana",
                    signButtonLabelText: "Sign in",
                    message: viewModel.solanaChallengeMessage ?? "",
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
                                    message: viewModel.bittensorChallengeMessage ?? "",
                                    signature: signature,
                                    publicKey: pk
                                )
                            } else {
                                await handleSolanaWalletResult(
                                    message: viewModel.solanaChallengeMessage ?? "",
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
    
    /// The Solana tile's tap: the sign-in sheet when a wallet app can take the
    /// hand-off, otherwise the no-wallet alert (iOS probes Phantom and Solflare;
    /// macOS always has the bridge).
    private func startSolanaSignIn() {
        #if os(iOS)
        let walletInstalled = connectWalletProviderViewModel.isWalletAppInstalled(.phantom)
            || connectWalletProviderViewModel.isWalletAppInstalled(.solflare)
        if !walletInstalled {
            presentNoSolanaWalletAlert = true
            return
        }
        #endif
        Task {
            let ok = await viewModel.prepareSolanaChallenge()
            if ok {
                viewModel.setPresentSigninWithSolanaSheet(true)
            }
        }
    }

    private func handleSolanaWalletResult(message: String, signature: String, publicKey: String) async {
        print("handleSolanaWalletResult")

        if viewModel.isSigningForCreateNetwork {
            viewModel.isSigningForCreateNetwork = false
            viewModel.setIsSigningMessage(false)
            viewModel.presentSigninWithSolanaSheet = false

            let createArgsResult = viewModel.createSolanaAuthLoginArgs(message: message, signature: signature, publicKey: publicKey)
            switch createArgsResult {
            case .success(let args):
                navigate(.createNetwork(args))
            case .failure(let error):
                print("error create args result: \(error.localizedDescription)")
                viewModel.setLoginErrorMessage("There was an error logging in")
            }
            return
        }

        guard viewModel.beginLoginAction(.solana) else {
            return
        }

        defer {
            viewModel.endLoginAction(.solana)
        }

        let createArgsResult = viewModel.createSolanaAuthLoginArgs(message: message, signature: signature, publicKey: publicKey)
        switch createArgsResult {
        case .success(let args):

            let result = await viewModel.authLogin(args: args)
            await self.handleAuthLoginResult(result)
            viewModel.presentSigninWithSolanaSheet = false
            viewModel.setIsSigningMessage(false)

        case .failure(let error):
            print("error create args result: \(error.localizedDescription)")
            viewModel.setIsSigningMessage(false)
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
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
            let result = await viewModel.authLogin(args: args)
            await self.handleAuthLoginResult(result)
        
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
                let result = await viewModel.authLogin(args: args)
                await self.handleAuthLoginResult(result)
            
            case .failure(let error):
                print("error create args result: \(error.localizedDescription)")
                viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
            }
            
         } catch {
             print("Error signing in: \(error.localizedDescription)")
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

            if authLoginArgs.walletAuth != nil {
                // the wallet challenge behind authLoginArgs was already
                // consumed by the /auth/login call that just returned this
                // .create case — fetch and sign a brand-new one before
                // creating the network. Which wallet flow to re-arm depends
                // on which one the user actually signed in with, not just
                // "any wallet" - bittensor and solana each need their own
                // challenge fetch and reopen the right sign-in surface.
                viewModel.isSigningForCreateNetwork = true
                if connectWalletProviderViewModel.connectedWalletProvider == .bittensor {
                    let ok = await viewModel.prepareBittensorChallenge(
                        walletAddress: authLoginArgs.walletAuth?.publicKey
                    )
                    if ok {
                        connectWalletProviderViewModel.openBittensorSignIn(
                            message: viewModel.bittensorChallengeMessage ?? ""
                        )
                    } else {
                        viewModel.isSigningForCreateNetwork = false
                    }
                } else {
                    let ok = await viewModel.prepareSolanaChallenge(
                        walletAddress: authLoginArgs.walletAuth?.publicKey
                    )
                    if ok {
                        viewModel.setPresentSigninWithSolanaSheet(true)
                    } else {
                        viewModel.isSigningForCreateNetwork = false
                    }
                }
            } else {
                navigate(.createNetwork(authLoginArgs))
            }
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
    
    private func handleBittensorSignIn() {
        Task {
            let ok = await viewModel.prepareBittensorChallenge()
            if ok {
                connectWalletProviderViewModel.openBittensorSignIn(
                    message: viewModel.bittensorChallengeMessage ?? ""
                )
            }
        }
    }

    private func handleBittensorWalletResult(message: String, signature: String, publicKey: String) async {

        if viewModel.isSigningForCreateNetwork {
            viewModel.isSigningForCreateNetwork = false
            viewModel.setIsSigningMessage(false)

            let createArgsResult = viewModel.createBittensorAuthLoginArgs(message: message, signature: signature, publicKey: publicKey)
            switch createArgsResult {
            case .success(let args):
                navigate(.createNetwork(args))
            case .failure(let error):
                print("error create args result: \(error.localizedDescription)")
                viewModel.setLoginErrorMessage("There was an error logging in")
            }
            return
        }

        guard viewModel.beginLoginAction(.bittensor) else {
            return
        }

        defer {
            viewModel.endLoginAction(.bittensor)
        }

        let createArgsResult = viewModel.createBittensorAuthLoginArgs(message: message, signature: signature, publicKey: publicKey)
        switch createArgsResult {
        case .success(let args):

            let result = await viewModel.authLogin(args: args)
            await self.handleAuthLoginResult(result)
            viewModel.setIsSigningMessage(false)

        case .failure(let error):
            print("error create args result: \(error.localizedDescription)")
            viewModel.setIsSigningMessage(false)
            viewModel.setLoginErrorMessage(String(localized: "There was an error logging in"))
        }
    }
    
}

private struct LoginInitialFormView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
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

    let presentSeedphraseLogin: () -> Void
    let presentCreateInstant: () -> Void
    
    @State private var presentNetworkServerSheet = false
    
    // The login stack rule shared by every app: up to three full-width
    // buttons (Apple, Google, Create Instant Account), then the remaining
    // methods as square icon tiles four per row with each row filled
    // (Secret key, Auth code, Bittensor, Solana), then the "or" divider and
    // the email / phone form.
    var body: some View {
        
        VStack {
            
            LoginFullButtons(
                handleAppleLoginResult: handleAppleLoginResult,
                handleGoogleSignInButton: handleGoogleSignInButton,
                presentCreateInstant: presentCreateInstant,
                activeLoginAction: activeLoginAction,
                isLoginActionInFlight: isLoginActionInFlight
            )
            
            Spacer()
                .frame(height: LoginStackMetrics.gap)
            
            LoginTiles(
                presentSeedphraseLogin: presentSeedphraseLogin,
                presentAuthCodeLoginSheet: presentAuthCodeLoginSheet,
                signInWithBittensor: signInWithBittensor,
                presentSignInWithSolanaSheet: presentSignInWithSolanaSheet,
                activeLoginAction: activeLoginAction,
                isLoginActionInFlight: isLoginActionInFlight
            )
            
            Spacer()
                .frame(height: 8)
            
            UrInlineErrorText(message: loginErrorMessage)
            
            Spacer()
                .frame(height: 16)
            
            Text("or", comment: "Referring to the two options 'Get started' *or* 'Login with Apple'")
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            
            Spacer()
                .frame(height: 16)
         
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
                    
                },
                accessibilityIdentifier: "acceptance.password.user"
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
                    
                },
                accessibilityIdentifier: "acceptance.password.user"
            )
            #endif
            
            Spacer()
                .frame(height: 16)
            
            UrButton(
                text: "Get started",
                action: {
                    Task {
                        await handleUserAuth()
                    }
                },
                enabled: isValidUserAuth && !isLoginActionInFlight,
                isProcessing: activeLoginAction == .userAuth,
                accessibilityIdentifier: "acceptance.password.next"
            )
            
            Spacer()
                .frame(height: 8)

            HStack {
                Button(action: {
                    presentNetworkServerSheet = true
                }) {
                    Text("Change Network API")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
                .disabled(isLoginActionInFlight)

                Spacer()
            }
            
        }
        .frame(maxWidth: 400)
        .sheet(isPresented: $presentNetworkServerSheet) {
            NetworkServerSheet(
                initialHostName: deviceManager.activeHostName,
                currentApiUrl: deviceManager.activeApiUrl,
                currentConnectUrl: deviceManager.activePlatformUrl,
                configuredApiUrl: deviceManager.configuredApiUrl,
                configuredConnectUrl: deviceManager.configuredPlatformUrl,
                managerAvailable: deviceManager.networkSpaceManager != nil,
                onApply: { hostName, apiUrl, connectUrl in
                    deviceManager.applyNetworkSpace(hostName: hostName, apiUrl: apiUrl, connectUrl: connectUrl)
                },
                dismiss: {
                    presentNetworkServerSheet = false
                }
            )
            .environmentObject(themeManager)
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }
    }
}

// The stack's metrics per platform: iOS keeps its 48pt capsules, macOS its
// compact 30pt rounded rows; the tiles follow the same pill treatment.
private enum LoginStackMetrics {
    #if os(iOS)
    static let pillHeight: CGFloat = 48
    static let pillFont: CGFloat = 19
    static let pillIcon: CGFloat = 16
    static let gap: CGFloat = 12
    static let tileHeight: CGFloat = 64
    static let tileRadius: CGFloat = 14
    static let tileIcon: CGFloat = 22
    static let tileCaption: CGFloat = 11
    #else
    static let pillHeight: CGFloat = 30
    static let pillFont: CGFloat = 12
    static let pillIcon: CGFloat = 12
    static let gap: CGFloat = 8
    static let tileHeight: CGFloat = 48
    static let tileRadius: CGFloat = 8
    static let tileIcon: CGFloat = 14
    static let tileCaption: CGFloat = 10
    #endif
    static let tileGap: CGFloat = 8
    static let tilesPerRow = 4
}

// The pill shape of the full-width buttons: a capsule on iOS, the compact
// 6pt rounded rectangle on macOS (what the existing rows use).
private struct LoginPillShape: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.clipShape(Capsule())
        #else
        content.cornerRadius(6)
        #endif
    }
}

private extension View {
    func loginPill() -> some View {
        modifier(LoginPillShape())
    }
}

// The up-to-three full-width buttons: Apple (the native button), Google and
// Create Instant Account.
private struct LoginFullButtons: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let handleAppleLoginResult: (Result<ASAuthorization, Error>) async -> Void
    let handleGoogleSignInButton: () async -> Void
    let presentCreateInstant: () -> Void
    let activeLoginAction: LoginInitialView.LoginAction?
    let isLoginActionInFlight: Bool
    
    var body: some View {
        
        VStack(spacing: LoginStackMetrics.gap) {
            
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                Task {
                    await handleAppleLoginResult(result)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: LoginStackMetrics.pillHeight)
            .signInWithAppleButtonStyle(.white)
            .buttonStyle(.plain)
            .loginPill()
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
            
            UrGoogleSignInButton(
                action: handleGoogleSignInButton,
                enabled: !isLoginActionInFlight,
                isProcessing: activeLoginAction == .google
            )
            .buttonStyle(.plain)
            
            // Instant create account button
            Button(action: presentCreateInstant) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: LoginStackMetrics.pillIcon)
                    Spacer().frame(width: 8)
                    Text("Create Instant Account")
                        .foregroundColor(themeManager.currentTheme.inverseTextColor)
                        .font(
                            Font.system(size: LoginStackMetrics.pillFont, weight: .medium)
                        )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: LoginStackMetrics.pillHeight)
            .frame(maxWidth: .infinity)
            .background(.white)
            .loginPill()
            .buttonStyle(.plain)
            .opacity(isLoginActionInFlight ? 0.3 : 1)
            .disabled(isLoginActionInFlight)
            .accessibilityIdentifier("acceptance.login.instant")
            
        }
        
    }
}

private enum LoginTileIcon {
    case system(String)
    case asset(String)
    case glyph(String)
}

private struct LoginTileSpec: Identifiable {
    let id: String
    let caption: LocalizedStringKey
    let icon: LoginTileIcon
    let action: () -> Void
    // the login action this tile starts, for its in-flight spinner
    let loginAction: LoginInitialView.LoginAction?
    let accessibilityIdentifier: String
}

// The remaining sign-in methods as square icon tiles: four per row, each
// row's tiles stretched to fill it, the rows as wide as the pills above.
private struct LoginTiles: View {
    
    #if os(iOS)
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    #endif
    
    let presentSeedphraseLogin: () -> Void
    let presentAuthCodeLoginSheet: () -> Void
    let signInWithBittensor: () -> Void
    let presentSignInWithSolanaSheet: () -> Void
    let activeLoginAction: LoginInitialView.LoginAction?
    let isLoginActionInFlight: Bool
    
    // The Solana tile is always the fourth small button, like every other
    // platform's login stack. iOS deep links into an installed wallet app
    // (Phantom or Solflare); the tap tells the user when there is none.
    // macOS routes through the ur.io/wallet-connect bridge.
    private var showSolana: Bool { true }
    
    private var tiles: [LoginTileSpec] {
        var list: [LoginTileSpec] = [
            LoginTileSpec(
                id: "secret_key",
                caption: "Seed",
                icon: .system("key.fill"),
                action: presentSeedphraseLogin,
                loginAction: nil,
                accessibilityIdentifier: "acceptance.login.secret"
            ),
            LoginTileSpec(
                id: "auth_code",
                caption: "Auth code",
                icon: .asset("ur.symbols.auth_code"),
                action: presentAuthCodeLoginSheet,
                loginAction: nil,
                accessibilityIdentifier: "acceptance.login.authcode"
            ),
            // Bittensor sign in runs through the ur.io/wallet-connect bridge,
            // so it does not depend on an installed wallet app
            LoginTileSpec(
                id: "bittensor",
                caption: "Bittensor",
                icon: .glyph("τ"),
                action: signInWithBittensor,
                loginAction: .bittensor,
                accessibilityIdentifier: "acceptance.login.bittensor"
            ),
        ]
        if showSolana {
            list.append(
                LoginTileSpec(
                    id: "solana",
                    caption: "Solana",
                    icon: .asset("solana.gradient.logo"),
                    action: presentSignInWithSolanaSheet,
                    loginAction: .solana,
                    accessibilityIdentifier: "acceptance.login.solana"
                )
            )
        }
        return list
    }
    
    // rows of four, in order
    private var rows: [[LoginTileSpec]] {
        let all = tiles
        return stride(from: 0, to: all.count, by: LoginStackMetrics.tilesPerRow).map { start in
            Array(all[start..<min(start + LoginStackMetrics.tilesPerRow, all.count)])
        }
    }
    
    var body: some View {
        VStack(spacing: LoginStackMetrics.tileGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: LoginStackMetrics.tileGap) {
                    ForEach(row) { tile in
                        LoginTileButton(
                            spec: tile,
                            activeLoginAction: activeLoginAction,
                            isLoginActionInFlight: isLoginActionInFlight
                        )
                    }
                }
            }
        }
    }
}

private struct LoginTileButton: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let spec: LoginTileSpec
    let activeLoginAction: LoginInitialView.LoginAction?
    let isLoginActionInFlight: Bool
    
    private var isActive: Bool {
        spec.loginAction != nil && activeLoginAction == spec.loginAction
    }
    
    var body: some View {
        Button(action: spec.action) {
            VStack(spacing: 6) {
                ZStack {
                    if isActive {
                        ProgressView()
                            .tint(.urBlack)
                            .controlSize(.small)
                    } else {
                        icon
                    }
                }
                .frame(height: LoginStackMetrics.tileIcon)
                
                Text(spec.caption)
                    .foregroundColor(themeManager.currentTheme.inverseTextColor)
                    .font(Font.system(size: LoginStackMetrics.tileCaption, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: LoginStackMetrics.tileHeight)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: LoginStackMetrics.tileRadius, style: .continuous))
        .buttonStyle(.plain)
        .opacity(isLoginActionInFlight && !isActive ? 0.3 : 1)
        .disabled(isLoginActionInFlight)
        .accessibilityIdentifier(spec.accessibilityIdentifier)
    }
    
    @ViewBuilder
    private var icon: some View {
        switch spec.icon {
        case .system(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                .frame(width: LoginStackMetrics.tileIcon, height: LoginStackMetrics.tileIcon)
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: LoginStackMetrics.tileIcon, height: LoginStackMetrics.tileIcon)
        case .glyph(let text):
            Text(text)
                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                .font(Font.system(size: LoginStackMetrics.tileIcon, weight: .bold))
        }
    }
}

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
