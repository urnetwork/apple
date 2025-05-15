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
        
        private var api: SdkApi?
        
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
        
        init(api: SdkApi?) {
            self.api = api
        }
        
        func authLogin(args: SdkAuthLoginArgs) async -> AuthLoginResult {
            
            print("inside auth login")
            
            do {
                let result: AuthLoginResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                    
                    guard let self = self else { return }
                    
                    let callback = AuthLoginCallback { [weak self] result, error in
                        
                        guard let self = self else { return }
                        
                        if let error {

                            continuation.resume(throwing: error)
                            
                            return
                        }
                        
                        guard let result else {
                            
                            continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "No result found"]))
                            
                            return
                        }
                        
                        if let resultError = result.error {
                            
                            continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "result.error exists \(resultError.message)"]))
                            
                            return
                        }
                        
                        // JWT exists, proceed to authenticate network
                        if let jwt = result.network?.byJwt {
                            continuation.resume(returning: .login(jwt))
                            return
                        }
                        
                        // user auth requires password
                        if let authAllowed = result.authAllowed {
                            
                            if authAllowed.contains("password") {
                                
                                /**
                                 * Login
                                 */
                                continuation.resume(returning: .promptPassword(result))
                                
                            } else {
                                
                                /**
                                 * Trying to login with the wrong account
                                 * ie email is used with google, but trying that same email with apple
                                 */
                                
                                var acceptedAuthMethods: [String] = []
    
                                // loop authAllowed
                                for i in 0..<authAllowed.len() {
                                    acceptedAuthMethods.append(authAllowed.get(i))
                                }
    
                                guard acceptedAuthMethods.isEmpty else {
    
                                    let errMessage = "Please login with one of: \(acceptedAuthMethods.joined(separator: ", "))."
    
                                    continuation.resume(returning: .incorrectAuth(errMessage))
    
                                    return
                                }
                                
                            }
                            
                            return
                            
                        }
                                       
                        /**
                         * Create new network
                         */
                        continuation.resume(returning: .create(args))
                        
                    }
                    
                    if let api = api {
                        api.authLogin(args, callback: callback)
                    } else {
                        print("no api found")
                    }
        
                    
                }
                
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
            
            let result: LoginNetworkResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = NetworkCreateCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    if let result = result {
                        
                        if let resultError = result.error {

                            continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                            
                            return
                            
                        }
                        
                        if let network = result.network {
                            print("result.network exists! good to go")
                            
                            continuation.resume(returning: .successWithJwt(network.byJwt))
                            return
                            
                        } else {
                            continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "No network object found in result"]))
                            return
                        }
                        
                    }
                    
                }
                
                let args = SdkNetworkCreateArgs()
                args.terms = true
                args.guestMode = true
                
                api?.networkCreate(args, callback: callback)
                
            }
            
            DispatchQueue.main.async {
                self.isCreatingGuestNetwork = false
            }
            
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

private class AuthLoginCallback: SdkCallback<SdkAuthLoginResult, SdkAuthLoginCallbackProtocol>, SdkAuthLoginCallbackProtocol {
    func result(_ result: SdkAuthLoginResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum LoginError: Error {
    case appleLoginFailed
    case googleLoginFailed
    case googleNoResult
    case googleNoIdToken
    case inProgress
    case incorrectAuth(_ authAllowed: String)
}

