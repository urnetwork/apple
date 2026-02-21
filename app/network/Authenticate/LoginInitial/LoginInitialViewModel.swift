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
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private var urApiService: UrApiServiceProtocol
        
        @Published var userAuth: String = "" {
            didSet {
                isValidUserAuth = ValidationUtils.isValidUserAuth(userAuth)
            }
        }

        @Published private(set) var isValidUserAuth: Bool = false
        
        @Published private(set) var isCheckingUserAuth: Bool = false
        
        func setIsCheckingUserAuth(_ isChecking: Bool) -> Void {
            isCheckingUserAuth = isChecking
        }
        
        // TODO: deprecate this
        @Published private(set) var loginErrorMessage: String?
        
        /**
         * Guest mode
         */
        @Published private(set) var isCreatingGuestNetwork: Bool = false
        @Published var presentGuestNetworkSheet: Bool = false
        @Published var termsAgreed: Bool = false
        
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
        
        let termsLink = "https://ur.io/terms"
        
        let domain = "LoginInitialViewModel"
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }
        
        func authLogin(args: SdkAuthLoginArgs) async -> AuthLoginResult {
                        
            do {
                let result = try await urApiService.authLogin(args)
                
                self.setIsCheckingUserAuth(false)
                
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
        
        if isCheckingUserAuth {
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Auth login already in progress"]))
        }
        
        if !isValidUserAuth {
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Form invalid"]))
        }
        
        DispatchQueue.main.async {
            self.setIsCheckingUserAuth(true)
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

// MARK: create guest network
extension LoginInitialView.ViewModel {
    
    func createGuestNetwork() async -> LoginNetworkResult {
        
        if self.isCreatingGuestNetwork {
            return .failure(LoginError.inProgress)
        }
        
        self.isCreatingGuestNetwork = true
        
        do {
            
            let args = SdkNetworkCreateArgs()
            args.terms = true
            args.guestMode = true
            
            let result = try await urApiService.createNetwork(args)
            
            self.isCreatingGuestNetwork = false
            
            
            return result
            
        } catch(let error) {
            DispatchQueue.main.async {
                self.isCreatingGuestNetwork = false
            }
            return .failure(error)
        }
        
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

