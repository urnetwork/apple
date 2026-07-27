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
         * Auth code login
         */
        @Published var presentAuthCodeLoginSheet: Bool = false
        
        func setPresentAuthCodeLoginSheet(_ present: Bool) -> Void {
            presentAuthCodeLoginSheet = present
        }
        
        @Published private(set) var isProcessingAuthCode: Bool = false
        
        func setIsProcessingAuthCode(_ present: Bool) -> Void {
            isProcessingAuthCode = present
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
        func prepareSolanaChallenge() async -> Bool {
            let args = SdkAuthWalletChallengeArgs()
            args.blockchain = "solana"

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
         * Bittensor
         */
        @Published private(set) var bittensorChallengeMessage: String?

        /// Same server-issued challenge flow as prepareSolanaChallenge(), for
        /// the Bittensor wallet-connect bridge. Must be called again for
        /// every sign attempt - the server invalidates a challenge the
        /// moment it is checked, whether the check succeeds or fails.
        ///
        /// The server accepts blockchain="bittensor" (case-insensitively,
        /// also "tao"/"TAO") — confirmed against urnetwork/server#402 after
        /// that PR was extended to support Bittensor wallets alongside
        /// Solana in the challenge-based wallet auth flow.
        func prepareBittensorChallenge() async -> Bool {
            let args = SdkAuthWalletChallengeArgs()
            args.blockchain = "bittensor"

            do {
                let result = try await urApiService.authWalletChallenge(args)
                guard !result.messageTemplate.isEmpty else {
                    bittensorChallengeMessage = nil
                    setLoginErrorMessage("There was an error connecting to the network")
                    return false
                }
                bittensorChallengeMessage = result.messageTemplate
                return true
            } catch {
                bittensorChallengeMessage = nil
                setLoginErrorMessage("There was an error connecting to the network")
                return false
            }
        }
        
        let termsLink = "https://ur.io/terms"
        
        let domain = "LoginInitialViewModel"
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
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
    func createBittensorAuthLoginArgs(message: String, signature: String, publicKey: String) -> Result<SdkAuthLoginArgs, Error> {

        let args = SdkAuthLoginArgs()
        let walletAuth = SdkWalletAuthArgs()
        // publicKey is the ss58 address; the signature is sr25519 hex from
        // the ur.io/wallet-connect bridge
        walletAuth.blockchain = SdkTAO
        walletAuth.message = message
        walletAuth.signature = signature
        walletAuth.publicKey = publicKey

        args.walletAuth = walletAuth

        return .success(args)

    }
}
