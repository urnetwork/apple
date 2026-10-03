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
        
        // false until the server confirms a code was sent
        @Published private(set) var codeSent: Bool
        
        // set after a rate limit; Resend stays disabled until it passes
        @Published private(set) var cooldown: SendCooldown?
        
        private let now: () -> Date
        
        private var cancellables = Set<AnyCancellable>()
        
        private let domain = "CreateNetworkVerifyViewModel"
        
        // `sendNotice` is the outcome of the send that led to this screen
        init(api: SdkApi?, userAuth: String, sendNotice: VerifySendNotice, now: @escaping () -> Date = Date.init) {
            self.api = api
            self.userAuth = userAuth
            self.now = now
            self.codeSent = sendNotice == .sent
            self.resendErrorMessage = sendNotice.errorMessage
            self.cooldown = SendCooldown.after(sendNotice, now: now())
            self.resetBtnEnabled = self.cooldown == nil
        }
        
        // Counts a rate limit down: refreshes the minutes left and re-enables
        // Resend once the retry time has passed. The view calls it every second.
        func tick() {
            guard let cooldown = cooldown else {
                return
            }
            if let notice = cooldown.notice(at: now()) {
                resendErrorMessage = notice.errorMessage
            } else {
                self.cooldown = nil
                resetBtnEnabled = true
                resendErrorMessage = nil
            }
        }
        
        func setOtpErrorMessage(_ message: String?) {
            otpErrorMessage = message
        }
        
        func setResendErrorMessage(_ message: String?) {
            resendErrorMessage = message
        }
        
        // nil when a send is already in progress
        func resendOtp() async -> VerifySendNotice? {
            
            if isSendingOtp {
                return nil
            }
            
            self.resendErrorMessage = nil
            self.isSendingOtp = true
            self.resetBtnEnabled = false

            let (notice, retryAfterSeconds): (VerifySendNotice, Int) = await withCheckedContinuation { [weak self] continuation in
                
                let callback = AuthVerifySendCallback { result, err in
                    
                    if let err = err {
                        print(err.localizedDescription)
                    }
                    
                    let transportError = err != nil || result == nil
                    continuation.resume(returning: (
                        VerifySendNotice.decide(transportError: transportError, sendError: result?.error),
                        transportError ? 0 : (result?.error?.retryAfterSeconds ?? 0)
                    ))
                    
                }
                
                guard let self = self, let api = self.api else {
                    continuation.resume(returning: (.sendFailed, 0))
                    return
                }

                api.authVerifySend(verifySendArgs(userAuth: self.userAuth), callback: callback)

            }
            
            self.isSendingOtp = false
            applyResendNotice(notice, retryAfterSeconds: retryAfterSeconds)
            
            return notice
                
        }
        
        func applyResendNotice(_ notice: VerifySendNotice, retryAfterSeconds: Int) {
            if notice == .sent {
                self.codeSent = true
                self.startResendButtonTimer()
                return
            }
            // a rate limit keeps Resend disabled until the retry time; any other
            // failure re-enables it so the user can retry
            self.cooldown = SendCooldown.after(notice, retryAfterSeconds: retryAfterSeconds, now: now())
            self.resetBtnEnabled = self.cooldown == nil
            self.resendErrorMessage = notice.errorMessage
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
