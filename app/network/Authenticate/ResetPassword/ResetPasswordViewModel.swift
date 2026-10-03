//
//  ResetPasswordViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/07.
//

import Foundation
import URnetworkSdk

enum SendPasswordResetError: Error {
    case inProgress
}


extension ResetPasswordView {
    
    @MainActor
    class ViewModel: ObservableObject {

        private var api: SdkApi

        @Published var sendInProgress: Bool = false
        
        @Published private(set) var errorMessage: String?
        
        // set after a rate limit; Send stays disabled until it passes
        @Published private(set) var cooldown: SendCooldown?
        
        private let now: () -> Date
        
        func setErrorMessage(_ message: String?) {
            errorMessage = message
        }
        
        let domain = "ResetPasswordViewModel"
        
        init(api: SdkApi, now: @escaping () -> Date = Date.init) {
            self.api = api
            self.now = now
        }
        
        var sendEnabled: Bool {
            return !sendInProgress && cooldown == nil
        }
        
        // Counts a rate limit down: refreshes the minutes left and re-enables
        // Send once the retry time has passed. The view calls it every second.
        func tick() {
            guard let cooldown = cooldown else {
                return
            }
            if let notice = cooldown.notice(at: now()) {
                errorMessage = notice.resetErrorMessage
            } else {
                self.cooldown = nil
                errorMessage = nil
            }
        }
        
        // A request error is a failure. Otherwise the notice for the server's
        // answer; only `sent` means the link was sent, and any other notice is
        // already shown as `errorMessage`.
        func sendResetLink(_ userAuth: String) async -> Result<VerifySendNotice, Error> {
            
            if sendInProgress || cooldown != nil {
                return .failure(SendPasswordResetError.inProgress)
            }
            
            self.errorMessage = nil
            self.sendInProgress = true

            let (outcome, retryAfterSeconds): (Result<VerifySendNotice, Error>, Int) = await withCheckedContinuation { continuation in
                
                let callback = AuthPasswordResetCallback { result, error in
                    continuation.resume(returning: (
                        passwordResetOutcome(result: result, err: error),
                        result?.error?.retryAfterSeconds ?? 0
                    ))
                }
                
                self.api.authPasswordReset(passwordResetArgs(userAuth: userAuth), callback: callback)
                
            }
            
            self.sendInProgress = false
            if case .success(let notice) = outcome {
                applyNotice(notice, retryAfterSeconds: retryAfterSeconds)
            }
            return outcome
            
        }
        
        func applyNotice(_ notice: VerifySendNotice, retryAfterSeconds: Int) {
            cooldown = SendCooldown.after(notice, retryAfterSeconds: retryAfterSeconds, now: now())
            errorMessage = notice.resetErrorMessage
        }
        
    }
    
}

private class AuthPasswordResetCallback: SdkCallback<SdkAuthPasswordResetResult, SdkAuthPasswordResetCallbackProtocol>, SdkAuthPasswordResetCallbackProtocol {
    func result(_ result: SdkAuthPasswordResetResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
