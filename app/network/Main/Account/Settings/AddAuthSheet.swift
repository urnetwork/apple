//
//  AddAuthSheet.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk
import AuthenticationServices
import GoogleSignIn

struct AddAuthSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    #if os(macOS) && DIRECT_DOWNLOAD
    // the Google or Apple browser flow (BrowserSso) of the direct-download
    // build: the api origin the callback lives on, and the return
    // NetworkApp.onOpenURL routes here
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @State private var browserSsoAttempts = BrowserSsoAttemptStore()
    @State private var browserSsoTimeoutTask: Task<Void, Never>?
    #endif
    
    let api: UrApiServiceProtocol
    let networkUserViewModel: NetworkUserViewModel?
    /// Called once a sign-in method was added: an Apple, Google or wallet
    /// sign-in when AddAuth succeeds, an email or phone once its code is
    /// verified (a legacy guest's in-place conversion re-signs its jwt here).
    var onAdded: (() -> Void)?
    /// Called when the sheet closes on the code step: the email or phone is on
    /// the network but not verified yet (verified at its first sign-in instead).
    var onClosedUnverified: (() -> Void)?

    @StateObject private var verifyModel: AddedSignInVerifyModel

    // counts a rate limit down and ends the resend hold
    private let verifyTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Keyboard state of the code field
    @FocusState private var isCodeFieldFocused: Bool

    init(
        api: UrApiServiceProtocol,
        networkUserViewModel: NetworkUserViewModel?,
        onAdded: (() -> Void)? = nil,
        onClosedUnverified: (() -> Void)? = nil
    ) {
        self.api = api
        self.networkUserViewModel = networkUserViewModel
        self.onAdded = onAdded
        self.onClosedUnverified = onClosedUnverified
        _verifyModel = StateObject(wrappedValue: AddedSignInVerifyModel(api: api))
    }

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isAdding: Bool = false
    @State private var selectedMethod: AddAuthSheetMethod = .email
    @State private var addError: String?
    @State private var walletConnectionTask: Task<Void, Never>?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if let userAuth = verifyModel.userAuth {
                    verifyCodeView(userAuth: userAuth)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                    
                        Text("Add a sign-in method")
                            .font(themeManager.currentTheme.titleFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    
                        Text("Link another way to sign in to your account.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    
                        Spacer().frame(height: 16)
                    
                        Picker("Method", selection: $selectedMethod) {
                            // the direct-download build offers Apple and Google
                            // through the browser instead of the native SDKs (BrowserSso)
                            ForEach(addAuthSheetMethods(
                                appleAvailable: Config.isAppleSignInConfigured || Config.isBrowserSignInAvailable,
                                googleAvailable: Config.isGoogleSignInConfigured || Config.isBrowserSignInAvailable
                            ), id: \.self) { method in
                                switch method {
                                case .apple:
                                    Text("Apple").tag(method)
                                case .google:
                                    Text("Google").tag(method)
                                case .wallet:
                                    Text("Wallet").tag(method)
                                case .email:
                                    Text("Email").tag(method)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    
                        if selectedMethod == .apple {
                            appleSignInView
                        } else if selectedMethod == .google {
                            googleSignInView
                        } else if selectedMethod == .wallet {
                            walletSignInView
                        } else if selectedMethod == .email {
                            emailFields
                        }
                    
                        if let error = addError {
                            Text(error)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(.red)
                        }
                    
                        if selectedMethod == .email {
                            Spacer().frame(height: 16)
                        
                            UrButton(
                                text: "Add Sign-In Method",
                                action: {
                                    Task {
                                        await addAuth()
                                    }
                                },
                                enabled: !isAdding && formValid,
                                isProcessing: isAdding
                            )
                        }
                    }
                    .padding()
                }
            }
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .onReceive(verifyTimer) { _ in
                verifyModel.tick()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                if verifyModel.awaitingCode {
                    // the sign-in is on the network but not verified; the
                    // first sign-in with it asks for a code instead
                    onClosedUnverified?()
                }
                walletConnectionTask?.cancel()
                walletConnectionTask = nil
                connectWalletProviderViewModel.pendingAddAuthSignatureHandler = nil
                connectWalletProviderViewModel.pendingWalletAuthMessage = nil
                #if os(macOS) && DIRECT_DOWNLOAD
                cancelBrowserSignIn()
                #endif
            }
            #if os(macOS) && DIRECT_DOWNLOAD
            // the api's oauth callback handing a Google or Apple browser
            // sign-in back: only the attempt this sheet started is accepted
            .onReceive(deepLinkRouter.$pendingBrowserSso) { ssoReturn in
                guard ssoReturn != nil, let ssoReturn = deepLinkRouter.consumeBrowserSso() else { return }
                Task {
                    await completeBrowserSignIn(ssoReturn)
                }
            }
            #endif
        }
    }
    
    @Environment(\.dismiss) private var dismiss
    
    private var formValid: Bool {
        switch selectedMethod {
        case .email:
            return !email.isEmpty && password.count >= 12
        default:
            return true
        }
    }
    
    // MARK: - Apple Sign-In
    
    private var appleSignInView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with your Apple ID to add it as a sign-in method.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            
            #if os(iOS)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                Task {
                    await handleAppleResult(result)
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .cornerRadius(8)
            #else
            if Config.isBrowserSignInAvailable {
                // the direct-download build: Apple's own web flow in the browser
                UrButton(
                    text: "Sign in with Apple",
                    action: {
                        startBrowserSignIn(.apple)
                    },
                    enabled: !isAdding,
                    leadingSystemImage: "apple.logo",
                    isProcessing: isAdding
                )
            } else {
                Text("Apple Sign-In is available on iOS.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            #endif
        }
    }
    
    // MARK: - Google Sign-In
    
    private var googleSignInView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with Google to add it as a sign-in method.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            
            UrGoogleSignInButton(
                action: {
                    if Config.isBrowserSignInAvailable {
                        // the direct-download build: Google's web flow in the browser
                        startBrowserSignIn(.google)
                    } else {
                        await handleGoogleSignIn()
                    }
                },
                enabled: !isAdding,
                isProcessing: isAdding
            )
        }
    }

    // MARK: - Browser Sign-In (direct-download build)

    /// Opens the provider's authorize page in the default browser; the rest
    /// continues on the urnetwork://oauth/<provider> return
    /// (completeBrowserSignIn), or the attempt times out.
    private func startBrowserSignIn(_ provider: BrowserSsoProvider) {
        #if os(macOS) && DIRECT_DOWNLOAD
        isAdding = true
        addError = nil
        let attempt = browserSsoAttempts.begin(provider)
        guard let url = BrowserSso.authorizeURL(provider, apiUrl: deviceManager.activeApiUrl, state: attempt.state, nonce: attempt.nonce),
              NSWorkspace.shared.open(url) else {
            browserSsoAttempts.cancel()
            addError = String(localized: "Could not open the browser. Please try again.")
            isAdding = false
            return
        }
        browserSsoTimeoutTask?.cancel()
        let timeout = browserSsoAttempts.timeout
        browserSsoTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, browserSsoAttempts.pending == attempt else {
                return
            }
            browserSsoAttempts.cancel()
            addError = BrowserSso.Failure.expired.userMessage
            isAdding = false
        }
        #endif
    }

    private func cancelBrowserSignIn() {
        #if os(macOS) && DIRECT_DOWNLOAD
        browserSsoTimeoutTask?.cancel()
        browserSsoTimeoutTask = nil
        browserSsoAttempts.cancel()
        #endif
    }

    private func completeBrowserSignIn(_ ssoReturn: BrowserSso.Return) async {
        #if os(macOS) && DIRECT_DOWNLOAD
        let verdict = browserSsoAttempts.take(ssoReturn)
        if browserSsoAttempts.pending == nil {
            browserSsoTimeoutTask?.cancel()
            browserSsoTimeoutTask = nil
        }
        switch verdict {
        case .success(let idToken):
            do {
                // the identity token the way the native flows hand it over
                let args = SdkAddAuthArgs()
                args.authJwt = idToken
                args.authJwtType = ssoReturn.provider.rawValue

                let _ = try await api.addAuth(args)
                isAdding = false
                _ = await networkUserViewModel?.refreshNetworkUser()
                switch ssoReturn.provider {
                case .apple:
                    await signInAdded(.apple, userAuth: "", message: String(localized: "Apple sign-in method added"))
                case .google:
                    await signInAdded(.google, userAuth: "", message: String(localized: "Google sign-in method added"))
                }
            } catch(let error) {
                isAdding = false
                addError = error.localizedDescription
            }
        case .failure(let failure):
            print("browser sign-in: rejected \(ssoReturn.provider.rawValue) return: \(failure)")
            // a stray or replayed return must not fail the attempt in flight
            if failure.isStray {
                return
            }
            isAdding = false
            addError = failure.userMessage
        }
        #endif
    }
    
    // MARK: - Wallet Sign-In
    
    @State private var walletStep: WalletStep = .disconnected
    
    enum WalletStep: Equatable {
        case disconnected
        case connecting
        case connected(String)  // publicKey
        case signing
        
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }
    
    @State private var walletChallengeMessage: String = ""
    
    private var walletSignInView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a Solana wallet (Phantom or Solflare) to add it as a sign-in method.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            
            switch walletStep {
            case .disconnected:
                HStack(spacing: 12) {
                    Button(action: {
                        walletConnectionTask = Task {
                            await connectWallet(.phantom)
                        }
                    }) {
                        VStack {
                            Image("phantom.white.logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                                .padding()
                                .background(Color(hex: "#ab9ff2"))
                                .cornerRadius(12)
                            Text("Phantom")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isAdding || walletStep == .connecting)
                    
                    Button(action: {
                        walletConnectionTask = Task {
                            await connectWallet(.solflare)
                        }
                    }) {
                        VStack {
                            Image("solflare.logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                                .padding()
                                .background(.urWhite)
                                .cornerRadius(12)
                            Text("Solflare")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isAdding || walletStep == .connecting)
                }
                
            case .connecting:
                HStack {
                    ProgressView()
                    Text("Connecting to wallet...")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                
            case .connected(let publicKey):
                HStack {
                    Image(systemName: "wallet.pass.fill")
                        .foregroundColor(.green)
                    Text("Connected: \(publicKey.prefix(8))...")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                }
                
                if !walletChallengeMessage.isEmpty {
                    UrButton(
                        text: "Sign with Wallet",
                        action: {
                            Task {
                                await signWalletChallenge()
                            }
                        },
                        enabled: !isAdding && walletStep.isConnected,
                        isProcessing: isAdding
                    )
                }
                
            case .signing:
                HStack {
                    ProgressView()
                    Text("Waiting for wallet signature...")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }
        }
    }
    
    private func connectWallet(_ provider: ConnectedWalletProvider) async {
        isAdding = true
        addError = nil
        walletStep = .connecting
        
        // Set up the pending handler for when wallet signs back
        connectWalletProviderViewModel.pendingAddAuthSignatureHandler = { [self] publicKey, signature in
            Task { @MainActor in
                await completeWalletAuth(publicKey: publicKey, signature: signature)
            }
        }
        
        // Fetch the challenge first before connecting
        do {
            let challengeArgs = SdkAuthWalletChallengeArgs()
            challengeArgs.blockchain = "solana"
            let challengeResult = try await api.authWalletChallenge(challengeArgs)
            self.walletChallengeMessage = challengeResult.messageTemplate
            connectWalletProviderViewModel.pendingWalletAuthMessage = challengeResult.messageTemplate
        } catch {
            addError = "Failed to get wallet challenge: \(error.localizedDescription)"
            isAdding = false
            walletStep = .disconnected
            return
        }
        
        // Check if already connected
        if connectWalletProviderViewModel.connectedPublicKey != nil {
            walletStep = .connected(connectWalletProviderViewModel.connectedPublicKey!)
            isAdding = false
            return
        }
        
        // Open wallet connection
        let opened: Bool
        switch provider {
        case .phantom:
            opened = connectWalletProviderViewModel.connectPhantomWallet()
        case .solflare:
            opened = connectWalletProviderViewModel.connectSolflareWallet()
        case .bittensor:
            opened = false
        @unknown default:
            opened = false
        }
        
        if !opened {
            addError = "Could not open wallet. Please install it and try again."
            isAdding = false
            walletStep = .disconnected
            return
        }
        
        // We'll wait for the connect deep link to fire
        // The Sheet's onAppear sets up a polling timer
        await pollForWalletConnection()
    }
    
    private func pollForWalletConnection() async {
        // Poll for up to 60 seconds for the wallet to connect back
        for _ in 0..<60 {
            if Task.isCancelled { return }
            if let pk = connectWalletProviderViewModel.connectedPublicKey {
                walletStep = .connected(pk)
                isAdding = false
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            if Task.isCancelled { return }
        }
        addError = "Wallet connection timed out. Please try again."
        isAdding = false
        walletStep = .disconnected
    }
    
    private func signWalletChallenge() async {
        isAdding = true
        addError = nil
        walletStep = .signing
        
        guard let provider = connectWalletProviderViewModel.connectedWalletProvider else {
            addError = "Wallet not connected"
            isAdding = false
            walletStep = .disconnected
            return
        }
        
        let message = walletChallengeMessage
        let didStartSigning: Bool
        switch provider {
        case .phantom:
            didStartSigning = connectWalletProviderViewModel.signMessagePhantom(message: message)
        case .solflare:
            didStartSigning = connectWalletProviderViewModel.signMessageSolflare(message: message)
        case .bittensor:
            didStartSigning = false
        @unknown default:
            didStartSigning = false
        }
        
        if !didStartSigning {
            addError = "Failed to start wallet signing"
            isAdding = false
            walletStep = .connected(connectWalletProviderViewModel.connectedPublicKey ?? "")
        }
        // The pendingAddAuthSignatureHandler will complete the flow when the signature comes back
    }
    
    private func completeWalletAuth(publicKey: String, signature: String) async {
        do {
            let args = SdkAddAuthArgs()
            let walletAuth = SdkWalletAuthArgs()
            walletAuth.blockchain = SdkSOL
            walletAuth.publicKey = publicKey
            walletAuth.message = walletChallengeMessage
            walletAuth.signature = signature
            args.walletAuth = walletAuth
            
            let _ = try await api.addAuth(args)
            isAdding = false
            walletStep = .disconnected
            connectWalletProviderViewModel.pendingAddAuthSignatureHandler = nil
            connectWalletProviderViewModel.pendingWalletAuthMessage = nil
            _ = await networkUserViewModel?.refreshNetworkUser()
            await signInAdded(.wallet, userAuth: "", message: String(localized: "Wallet sign-in method added"))
        } catch(let error) {
            isAdding = false
            addError = error.localizedDescription
            walletStep = .disconnected
            connectWalletProviderViewModel.pendingAddAuthSignatureHandler = nil
            connectWalletProviderViewModel.pendingWalletAuthMessage = nil
        }
    }
    
    // MARK: - Email Fields
    
    private var emailFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            UrTextField(
                text: $email,
                label: "Email",
                placeholder: "your@email.com",
                disableCapitalization: true
            )
            
            UrTextField(
                text: $password,
                label: "Password",
                placeholder: "Enter a password",
                isSecure: true
            )
            
            Text("Password must be at least 12 characters")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }
    
    // MARK: - Actions
    
    private func handleAppleResult(_ result: Result<ASAuthorization, any Error>) async {
        isAdding = true
        addError = nil
        
        do {
            let authResult = try result.get()
            guard let credential = authResult.credential as? ASAuthorizationAppleIDCredential,
                  let idToken = credential.identityToken,
                  let idTokenString = String(data: idToken, encoding: .utf8) else {
                addError = "Could not read Apple ID token"
                isAdding = false
                return
            }
            
            let args = SdkAddAuthArgs()
            args.authJwt = idTokenString
            args.authJwtType = "apple"
            
            let _ = try await api.addAuth(args)
            isAdding = false
            _ = await networkUserViewModel?.refreshNetworkUser()
            await signInAdded(.apple, userAuth: "", message: String(localized: "Apple sign-in method added"))
        } catch(let error) {
            isAdding = false
            addError = error.localizedDescription
        }
    }
    
    private func handleGoogleSignIn() async {
        isAdding = true
        addError = nil
        
        do {
            #if os(iOS)
            guard let rootViewController = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.keyWindow?
                .rootViewController else {
                addError = "Could not get root view controller"
                isAdding = false
                return
            }
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            #elseif os(macOS)
            guard let presentingWindow = NSApplication.shared.windows.first else {
                addError = "Could not get presenting window"
                isAdding = false
                return
            }
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingWindow)
            #endif
            
            guard let idTokenString = signInResult.user.idToken?.tokenString else {
                addError = "Could not get Google ID token"
                isAdding = false
                return
            }
            
            let args = SdkAddAuthArgs()
            args.authJwt = idTokenString
            args.authJwtType = "google"
            
            let _ = try await api.addAuth(args)
            isAdding = false
            _ = await networkUserViewModel?.refreshNetworkUser()
            await signInAdded(.google, userAuth: "", message: String(localized: "Google sign-in method added"))
        } catch(let error) {
            isAdding = false
            addError = error.localizedDescription
        }
    }
    
    private func addAuth() async {
        isAdding = true
        addError = nil
        
        do {
            guard let args = addAuthButtonArgs(selectedMethod, email: email, password: password) else {
                isAdding = false
                return
            }
            
            let _ = try await api.addAuth(args)
            isAdding = false
            // the method now shows on the account, unverified
            _ = await networkUserViewModel?.refreshNetworkUser()
            // an email or phone is added once its code is verified (submitCode)
            await signInAdded(selectedMethod, userAuth: args.userAuth, message: String(localized: "Sign-in method added successfully"))
        } catch(let error) {
            isAdding = false
            addError = error.localizedDescription
        }
    }

    /// AddAuth succeeded: the sign-in counts as added now, or after its code.
    private func signInAdded(_ method: AddAuthSheetMethod, userAuth: String, message: String) async {
        if await verifyModel.methodAdded(method, userAuth: userAuth) {
            reportAdded(message)
        }
    }

    private func reportAdded(_ message: String) {
        snackbarManager.showSnackbar(message: message)
        onAdded?()
        dismiss()
    }

    private func submitCode() async {
        if await verifyModel.submit() {
            #if canImport(UIKit)
            hideKeyboard()
            #endif
            _ = await networkUserViewModel?.refreshNetworkUser()
            reportAdded(String(localized: "Sign-in method added successfully"))
        }
    }

    // MARK: - Verify Code

    // the login verify screen's code step (CreateNetworkVerifyView)
    @ViewBuilder
    private func verifyCodeView(userAuth: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // until a code is sent, do not say one was; the send error replaces the instructions
            if verifyModel.codeSent {
                Text(userAuth.isEmail() ? "You've got mail" : "Check your phone")
                    .font(themeManager.currentTheme.titleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            } else {
                Text("Verify")
                    .font(themeManager.currentTheme.titleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }

            Spacer().frame(height: 16)

            if verifyModel.codeSent {
                Text("Tell us who you really are. Enter the code we sent you to verify your identity.")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            } else {
                UrInlineErrorText(message: verifyModel.sendErrorMessage)
            }

            Spacer().frame(height: 32)

            HStack(spacing: 0) {
                ForEach(0..<verifyModel.codeCount, id: \.self) { index in
                    otpTextBox(index)
                }
            }
            .background {
                // hidden textfield which holds the code
                TextField("", text: $verifyModel.otp)
                    .onChange(of: verifyModel.otp) { newValue in
                        if newValue.count > verifyModel.codeCount {
                            verifyModel.otp = String(newValue.prefix(verifyModel.codeCount))
                        }
                        if verifyModel.otp.count == verifyModel.codeCount && !verifyModel.isVerifying && !verifyModel.isSending {
                            Task {
                                await submitCode()
                            }
                        }
                    }
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .blendMode(.screen)
                    .focused($isCodeFieldFocused)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .disabled(verifyModel.isVerifying || verifyModel.isSending)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !verifyModel.isVerifying && !verifyModel.isSending {
                    isCodeFieldFocused.toggle()
                }
            }

            if verifyModel.isVerifying {
                Spacer().frame(height: 12)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .frame(maxWidth: .infinity)
            }

            Spacer().frame(height: 8)

            UrInlineErrorText(message: verifyModel.otpErrorMessage)

            Spacer().frame(height: 32)

            HStack {
                Text("Don't see it? ", comment: "Referring to the OTP code")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .font(themeManager.currentTheme.secondaryBodyFont)

                Button(action: {
                    Task {
                        // a failed send sets the model's error message
                        if await verifyModel.resend() == .sent {
                            snackbarManager.showSnackbar(message: String(localized: "Verification code sent."))
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Text("Resend code")
                            .foregroundColor(themeManager.currentTheme.textColor)
                            .font(themeManager.currentTheme.secondaryBodyFont)

                        if verifyModel.isSending {
                            ProgressView()
                                .tint(themeManager.currentTheme.textColor)
                                .controlSize(.small)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!verifyModel.resendEnabled)
            }

            if verifyModel.codeSent {
                Spacer().frame(height: 8)

                UrInlineErrorText(message: verifyModel.sendErrorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func otpTextBox(_ index: Int) -> some View {
        ZStack {
            if verifyModel.otp.count > index {
                let charIndex = verifyModel.otp.index(verifyModel.otp.startIndex, offsetBy: index)
                Text(String(verifyModel.otp[charIndex]))
                    .font(Font.custom("PPNeueBit-Bold", size: 24))
            } else {
                Text(" ")
            }
        }
        .frame(width: 38, height: 38)
        .background {
            let isFocused = (isCodeFieldFocused && index == verifyModel.otp.count)

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
