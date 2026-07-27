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
    
    let api: UrApiServiceProtocol
    let networkUserViewModel: NetworkUserViewModel?

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isAdding: Bool = false
    @State private var selectedMethod: String = "email"
    @State private var addError: String?
    @State private var walletConnectionTask: Task<Void, Never>?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    Text("Add a sign-in method")
                        .font(themeManager.currentTheme.titleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Text("Link another way to sign in to your account.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    
                    Spacer().frame(height: 16)
                    
                    Picker("Method", selection: $selectedMethod) {
                        Text("Apple").tag("apple")
                        Text("Google").tag("google")
                        Text("Wallet").tag("wallet")
                        Text("Email").tag("email")
                        Text("Seedphrase").tag("seedphrase")
                    }
                    .pickerStyle(.menu)
                    
                    if selectedMethod == "apple" {
                        appleSignInView
                    } else if selectedMethod == "google" {
                        googleSignInView
                    } else if selectedMethod == "wallet" {
                        walletSignInView
                    } else if selectedMethod == "email" {
                        emailFields
                    } else if selectedMethod == "seedphrase" {
                        Text("A new seedphrase will be generated and linked to your account.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    
                    if let error = addError {
                        Text(error)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(.red)
                    }
                    
                    if selectedMethod == "email" || selectedMethod == "seedphrase" {
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
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                walletConnectionTask?.cancel()
                walletConnectionTask = nil
                connectWalletProviderViewModel.pendingAddAuthSignatureHandler = nil
                connectWalletProviderViewModel.pendingWalletAuthMessage = nil
            }
        }
    }
    
    @Environment(\.dismiss) private var dismiss
    
    private var formValid: Bool {
        switch selectedMethod {
        case "email":
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
            Text("Apple Sign-In is available on iOS.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
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
                    await handleGoogleSignIn()
                }
            )
        }
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
            snackbarManager.showSnackbar(message: String(localized: "Wallet sign-in method added"))
            dismiss()
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
            snackbarManager.showSnackbar(message: String(localized: "Apple sign-in method added"))
            dismiss()
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
            snackbarManager.showSnackbar(message: String(localized: "Google sign-in method added"))
            dismiss()
        } catch(let error) {
            isAdding = false
            addError = error.localizedDescription
        }
    }
    
    private func addAuth() async {
        isAdding = true
        addError = nil
        
        do {
            let args = SdkAddAuthArgs()
            
            switch selectedMethod {
            case "email":
                args.userAuth = email
                args.password = password
            case "seedphrase":
                // Seedphrase is generated server-side when no auth fields are set
                // Just call addAuth with empty args to trigger seedphrase linking
                break
            default:
                break
            }
            
            let _ = try await api.addAuth(args)
            isAdding = false
            _ = await networkUserViewModel?.refreshNetworkUser()
            snackbarManager.showSnackbar(message: String(localized: "Sign-in method added successfully"))
            dismiss()
        } catch(let error) {
            isAdding = false
            addError = error.localizedDescription
        }
    }
}
