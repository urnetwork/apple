//
//  LoginPasswordViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import Foundation
import URnetworkSdk
import SwiftUI

private class AuthLoginPasswordCallback: SdkCallback<SdkAuthLoginWithPasswordResult, SdkAuthLoginWithPasswordCallbackProtocol>, SdkAuthLoginWithPasswordCallbackProtocol {
    func result(_ result: SdkAuthLoginWithPasswordResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

extension LoginPasswordView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private var api: SdkApi?
        
        @Published private(set) var isValid: Bool = false
        
        @Published private(set) var isLoggingIn: Bool = false
        
        @Published private(set) var errorMessage: String?
        
        @Published var password: String = "" {
            didSet {
                isValid = !password.isEmpty
                errorMessage = nil
            }
        }
        
        private let domain = "LoginPassword.ViewModel"
        
        init(api: SdkApi?) {
            self.api = api
        }
        
        func setIsLoggingIn(_ isLoggingIn: Bool) {
            self.isLoggingIn = isLoggingIn
        }
        
        func setErrorMessage(_ message: String?) {
            self.errorMessage = message
        }
        
        func loginWithPassword(userAuth: String) async -> LoginNetworkResult {
            
            if !isValid {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Form invalid"]))
            }
            
            if isLoggingIn {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Login already in progress"]))
            }
            
            self.setIsLoggingIn(true)
            
            do {
                let result: LoginNetworkResult = try await withCheckedThrowingContinuation { continuation in
                    
                    let callback = AuthLoginPasswordCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        if let result = result {
                            
                            if let resultError = result.error {

                                continuation.resume(throwing: NSError(domain: "LoginPassword.ViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                                
                                return
                                
                            }
                            
                            
                            if let verificationRequired = result.verificationRequired {
                                continuation.resume(returning: .successWithVerificationRequired(
                                    VerifySendNotice.decide(transportError: false, sendError: verificationRequired.sendError)
                                ))
                                return
                            }
                            
                            if let network = result.network {
                                guard !network.byJwt.isEmpty else {
                                    continuation.resume(throwing: NSError(domain: "LoginPassword.ViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "byJWT is empty"]))
                                    return
                                }

                                continuation.resume(returning: .successWithJwt(network.byJwt))
                                return
                                
                            } else {
                                continuation.resume(throwing: NSError(domain: "LoginPassword.ViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network object found in result"]))
                                return
                            }
                            
                        } else {
                            continuation.resume(throwing: NSError(domain: "LoginPassword.ViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "No error or result found"])
                            )
                        }
                        
                    }
                    
                    let args = SdkAuthLoginWithPasswordArgs()
                    args.userAuth = userAuth
                    args.password = self.password
                    args.verifyOtpNumeric = true
                    
                    if let api = api {
                        
                        api.authLogin(withPassword: args, callback: callback)
                        
                    } else {
                        continuation.resume(throwing: NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "API not instantiated"]))
                    }
                    
                }
                
                setIsLoggingIn(false)
                return result
            } catch {
                setIsLoggingIn(false)
                return .failure(error)
            }
            
        }
    }
}
