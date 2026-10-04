//
//  LoginInitialViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/20.
//

import Foundation
import URnetworkSdk
import SwiftUI
import AuthenticationServices
import GoogleSignIn
import Combine

extension LoginInitialView {
    
    enum LoginAction: Equatable {
        case userAuth
        case apple
        case google
        case solana
        case bittensor
    }
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private var urApiService: UrApiServiceProtocol

        // the Google or Apple browser attempt in flight (direct-download
        // build): see startBrowserSso below
        let browserSsoAttempts = BrowserSsoAttemptStore()
        var browserSsoTimeoutTask: Task<Void, Never>?
        
        @Published var userAuth: String = "" {
            didSet {
                isValidUserAuth = ValidationUtils.isValidUserAuth(userAuth)
                loginErrorMessage = nil
            }
        }

        @Published private(set) var isValidUserAuth: Bool = false
        
        @Published private(set) var activeLoginAction: LoginAction?
        
        var isCheckingUserAuth: Bool {
            activeLoginAction == .userAuth
        }
        
        var isLoginActionInFlight: Bool {
            activeLoginAction != nil
        }
        
        func setIsCheckingUserAuth(_ isChecking: Bool) -> Void {
            activeLoginAction = isChecking ? .userAuth : nil
        }
        
        func beginLoginAction(_ action: LoginAction) -> Bool {
            if activeLoginAction != nil {
                return false
            }
            
            loginErrorMessage = nil
            activeLoginAction = action
            return true
        }
        
        func endLoginAction(_ action: LoginAction) -> Void {
            if activeLoginAction == action {
                activeLoginAction = nil
            }
        }
        
        // TODO: deprecate this
        @Published private(set) var loginErrorMessage: String?
        
        func setLoginErrorMessage(_ message: String?) -> Void {
            loginErrorMessage = message
        }
        
        /**
         * Solana
         */
        @Published var presentSigninWithSolanaSheet: Bool = false
        
        func setPresentSigninWithSolanaSheet(_ present: Bool) -> Void {
            presentSigninWithSolanaSheet = present
        }
        
        @Published private(set) var isSigningMessage: Bool = false
        
        func setIsSigningMessage(_ isSigning: Bool) -> Void {
            isSigningMessage = isSigning
        }

        @Published private(set) var solanaChallengeMessage: String?

        @Published var isSigningForCreateNetwork: Bool = false

        /// Fetches a fresh, server-issued wallet-auth challenge and stores its
        /// message template for the wallet to sign. Must be called again for
        /// every sign attempt — the server invalidates a challenge the moment
        /// it is checked, whether the check succeeds or fails.
        func prepareSolanaChallenge(walletAddress: String? = nil) async -> Bool {
            let args = SdkAuthWalletChallengeArgs()
            args.blockchain = "solana"
            if let walletAddress, !walletAddress.isEmpty {
                args.walletAddress = walletAddress
            }

            do {
                let result = try await urApiService.authWalletChallenge(args)
                guard !result.messageTemplate.isEmpty else {
                    solanaChallengeMessage = nil
                    setLoginErrorMessage("There was an error connecting to the network")
                    return false
                }
                solanaChallengeMessage = result.messageTemplate
                return true
            } catch {
                solanaChallengeMessage = nil
                setLoginErrorMessage("There was an error connecting to the network")
                return false
            }
        }

        /**
         * Bittensor: the SDK wallet-connect session (Talisman, TAO.com or WalletConnect).
         * Every sign attempt fetches a new challenge - the server invalidates
         * one the moment it is checked, whether the check succeeds or fails.
         */
        let bittensorConnector: BittensorWalletConnector
        private var bittensorConnectorChanges: AnyCancellable?

        let termsLink = "https://ur.io/terms"
        
        let domain = "LoginInitialViewModel"
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
            self.bittensorConnector = BittensorWalletConnector(
                fetchChallenge: { args in
                    try await urApiService.authWalletChallenge(args)
                }
            )
            // the sign-in sheet follows the connector's stage
            bittensorConnectorChanges = bittensorConnector.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        
        func authLogin(args: SdkAuthLoginArgs) async -> AuthLoginResult {
                        
            do {
                let result = try await urApiService.authLogin(args)
                return result
                
            } catch {
                return .failure(error)
            }
            
        }        
    }
}

// MARK: Handle UserAuth Login
extension LoginInitialView.ViewModel {
    
    // func getStarted() async -> AuthLoginResult {
    func getStarted() -> Result<SdkAuthLoginArgs, Error> {
        
        if isLoginActionInFlight {
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Auth login already in progress"]))
        }
        
        if !isValidUserAuth {
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Form invalid"]))
        }
        
        let args = SdkAuthLoginArgs()
        args.userAuth = userAuth
        
        return .success(args)
        
    }
    
}

// MARK: Handle Apple Login
extension LoginInitialView.ViewModel {
    
    func createAppleAuthLoginArgs(_ result: Result<ASAuthorization, any Error>) -> Result<SdkAuthLoginArgs, Error> {
        
        switch result {
            
            case .success(let authResults):
                
                // get the id token to use as authJWT
                switch authResults.credential {
                    case let credential as ASAuthorizationAppleIDCredential:
                    
                    guard let idToken = credential.identityToken else {
                        return .failure(LoginError.appleLoginFailed)
                    }
                    
                    guard let idTokenString = String(data: idToken, encoding: .utf8) else {
                        return .failure(LoginError.appleLoginFailed)
                    }
                        
                    let args = SdkAuthLoginArgs()
                    args.authJwt = idTokenString
                    args.authJwtType = "apple"
                    
                    return .success(args)

                default:
                        
                    return .failure(LoginError.appleLoginFailed)
                }
                
            
            case .failure(let error):
                print("Authorisation failed: \(error.localizedDescription)")
                return .failure(error)
            
        }
        
    }
    
}

// MARK: handle Google login result
extension LoginInitialView.ViewModel {
    
    func createGoogleAuthLoginArgs(_ result: GIDSignInResult?) -> Result<SdkAuthLoginArgs, Error> {
        
        guard let result = result else {
            return .failure(LoginError.googleNoResult)
        }
        
        guard let idTokenString = result.user.idToken?.tokenString else {
            return .failure(LoginError.googleNoIdToken)
        }
        
        let args = SdkAuthLoginArgs()
        args.authJwt = idTokenString
        args.authJwtType = "google"
        
        return .success(args)
        
    }
    
}

// MARK: Solana Sign in
extension LoginInitialView.ViewModel {
    func createSolanaAuthLoginArgs(message: String, signature: String, publicKey: String) -> Result<SdkAuthLoginArgs, Error> {

        let args = SdkAuthLoginArgs()
        let walletAuth = SdkWalletAuthArgs()
        walletAuth.blockchain = SdkSOL
        walletAuth.message = message
        walletAuth.signature = signature
        walletAuth.publicKey = publicKey

        args.walletAuth = walletAuth

        return .success(args)

    }
}

// MARK: Bittensor Sign in
extension LoginInitialView.ViewModel {
    /// The login args for a proof the SDK session accepted (the ss58 address,
    /// the issued challenge, the 0x sr25519 signature).
    func createBittensorAuthLoginArgs(_ proof: BittensorWalletProofInfo) -> SdkAuthLoginArgs {

        let args = SdkAuthLoginArgs()
        let walletAuth = SdkWalletAuthArgs()
        walletAuth.blockchain = SdkTAO
        walletAuth.message = proof.message
        walletAuth.signature = proof.signature
        walletAuth.publicKey = proof.address

        args.walletAuth = walletAuth

        return args

    }
}

// MARK: Browser sign in (Google and Apple without a native flow: the
// direct-download build, BrowserSso)
extension BrowserSsoProvider {
    /// The login action a browser attempt holds while the browser is open.
    var loginAction: LoginInitialView.LoginAction {
        switch self {
        case .google:
            return .google
        case .apple:
            return .apple
        }
    }
}

extension LoginInitialView.ViewModel {

    /// Starts a browser attempt: a fresh state + nonce, and the provider's
    /// authorize url for the view to open. Nil without an api origin (the
    /// attempt is not kept). The attempt expires on its own after
    /// BrowserSso.attemptTimeout: `onTimeout` runs then, on the main actor,
    /// unless a return ended the attempt first.
    func startBrowserSso(_ provider: BrowserSsoProvider, apiUrl: String, onTimeout: @escaping @MainActor () -> Void) -> URL? {
        let attempt = browserSsoAttempts.begin(provider)
        guard let url = BrowserSso.authorizeURL(provider, apiUrl: apiUrl, state: attempt.state, nonce: attempt.nonce) else {
            browserSsoAttempts.cancel()
            return nil
        }
        browserSsoTimeoutTask?.cancel()
        let timeout = browserSsoAttempts.timeout
        browserSsoTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.browserSsoAttempts.pending == attempt else {
                return
            }
            self.browserSsoAttempts.cancel()
            onTimeout()
        }
        return url
    }

    /// Drops the attempt in flight (the browser could not be opened, the
    /// view went away).
    func cancelBrowserSso() {
        browserSsoTimeoutTask?.cancel()
        browserSsoTimeoutTask = nil
        browserSsoAttempts.cancel()
    }

    /// The api's return for the attempt in flight: accepted exactly once,
    /// only with the minted state echoed and a token minted for the nonce.
    /// The login args carry the identity token the way the native flows'
    /// do (auth_jwt + auth_jwt_type).
    func createBrowserSsoAuthLoginArgs(_ ssoReturn: BrowserSso.Return) -> Result<SdkAuthLoginArgs, BrowserSso.Failure> {
        let verdict = browserSsoAttempts.take(ssoReturn)
        if browserSsoAttempts.pending == nil {
            browserSsoTimeoutTask?.cancel()
            browserSsoTimeoutTask = nil
        }
        switch verdict {
        case .success(let idToken):
            let args = SdkAuthLoginArgs()
            args.authJwt = idToken
            args.authJwtType = ssoReturn.provider.rawValue
            return .success(args)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Ends whichever browser attempt's login action is active.
    func endBrowserSsoLoginAction() {
        if let action = activeLoginAction, action == .google || action == .apple {
            endLoginAction(action)
        }
    }
}
