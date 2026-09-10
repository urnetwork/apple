//
//  CreateNetworkVerifyViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/27.
//

import Foundation
import URnetworkSdk
import SwiftUI
import Combine

// for verifying the OTP
private class AuthVerifyCallback: SdkCallback<SdkAuthVerifyResult, SdkAuthVerifyCallbackProtocol>, SdkAuthVerifyCallbackProtocol {
    func result(_ result: SdkAuthVerifyResult?, err: Error?) {
        handleResult(result, err: err)
    }
}


// For resending the OTP
private class AuthVerifySendCallback: SdkCallback<SdkAuthVerifySendResult, SdkAuthVerifySendCallbackProtocol>, SdkAuthVerifySendCallbackProtocol {
    func result(_ result: SdkAuthVerifySendResult?, err: Error?) {
        handleResult(result, err: err)
    }
}


extension CreateNetworkVerifyView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private var api: SdkApi?
        
        private var userAuth: String
        
        let codeCount = 6
        
        @Published var otp: String = "" {
            didSet {
                otpErrorMessage = nil
            }
        }
        
        @Published private(set) var isSubmitting: Bool = false
        
        @Published private(set) var isSendingOtp: Bool = false
        
        @Published private(set) var otpErrorMessage: String?
        
        @Published private(set) var resendErrorMessage: String?
        
        @Published private(set) var resetBtnEnabled: Bool = true
        
        private var cancellables = Set<AnyCancellable>()
        
        private let domain = "CreateNetworkVerifyViewModel"
        
        init(api: SdkApi?, userAuth: String) {
            self.api = api
            self.userAuth = userAuth
        }
        
        func setOtpErrorMessage(_ message: String?) {
            otpErrorMessage = message
        }
        
        func setResendErrorMessage(_ message: String?) {
            resendErrorMessage = message
        }
        
        func resendOtp() async -> Result<Void, Error> {
            
            if isSendingOtp {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "OTP is already being sent"]))
            }
            
            self.resendErrorMessage = nil
            self.isSendingOtp = true
            self.resetBtnEnabled = false

            do {
                let result: Void = try await withCheckedThrowingContinuation { [weak self] continuation in
                    
                    let callback = AuthVerifySendCallback { result, err in
                        
                        if let err = err {
                            print(err.localizedDescription)
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        continuation.resume(returning: ())
                        
                    }
                    
                    guard let self = self, let api = self.api else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let args = SdkAuthVerifySendArgs()
                    args.userAuth = self.userAuth
                    args.useNumeric = true

                    api.authVerifySend(args, callback: callback)

                }
                
                
                self.isSendingOtp = false
                self.startResendButtonTimer()
                
                return .success(result)
                
            } catch {
                isSendingOtp = false
                // re-enable the resend button so the user can retry — a failed resend
                // otherwise leaves it permanently disabled (no timer re-enables it)
                resetBtnEnabled = true
                return .failure(error)
            }
                
        }
        
        
        private func startResendButtonTimer() {
            let delay = 15
            Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .scan(delay) { counter, _ in counter - 1 }
                .prefix(while: { $0 > 0 })
                .sink(receiveCompletion: { [weak self] _ in
                    self?.resetBtnEnabled = true
                }, receiveValue: { _ in })
                .store(in: &cancellables)
        }
        
        deinit {
            cancellables.removeAll()
        }
        
        func submit() async -> Result<String, Error> {
      
            if isSubmitting {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "OTP is already being sent"]))
            }
            
            self.otpErrorMessage = nil
            self.isSubmitting = true

            do {

                let result: String = try await withCheckedThrowingContinuation { [weak self] continuation in

                    let callback = AuthVerifyCallback { result, err in
                        
                        if let err = err {
                            print(err.localizedDescription)
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: NSError(domain: "CreateNetworkVerifyViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "verify result is nil"]))
                            return
                        }
                        
                        if let resultError = result.error {
                            continuation.resume(throwing: NSError(domain: "CreateNetworkVerifyViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))

                            return
                        }

                        if let network = result.network {

                            if network.byJwt.isEmpty == false {
                                continuation.resume(returning: network.byJwt)
                            } else {
                                continuation.resume(throwing: NSError(domain: "CreateNetworkVerifyViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "byJWT is empty"]))
                            }

                        } else {
                            continuation.resume(throwing: NSError(domain: "CreateNetworkVerifyViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "network is nil"]))
                        }
                        
                    }
                    
                    guard let self = self, let api = self.api else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let args = SdkAuthVerifyArgs()
                    args.verifyCode = self.otp
                    args.userAuth = self.userAuth

                    api.authVerify(args, callback: callback)

                }

                self.isSubmitting = false

                return .success(result)

            } catch {
                self.isSubmitting = false
                
                return .failure(error)
            }
        }
    }
}
