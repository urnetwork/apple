//
//  ProfileViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk

extension ProfileView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        var api: SdkApi
        
        @Published private(set) var isSendingPasswordResetLink: Bool = false
        @Published private(set) var sendPasswordResetLinkError: String?
        
        // set after a rate limit; "Update password" stays disabled until it passes
        @Published private(set) var passwordResetCooldown: SendCooldown?
        
        private let now: () -> Date
        
        @Published var isEditingNetworkName: Bool = false
        @Published var editedNetworkName: String = ""
        @Published private(set) var isSavingNetworkName: Bool = false
        @Published private(set) var networkNameError: String?
        
        init(api: SdkApi, now: @escaping () -> Date = Date.init) {
            self.api = api
            self.now = now
        }
        
        var passwordResetEnabled: Bool {
            return !isSendingPasswordResetLink && passwordResetCooldown == nil
        }
        
        // Counts a rate limit down: refreshes the minutes left and re-enables
        // "Update password" once the retry time has passed. The view calls it
        // every second.
        func tick() {
            guard let cooldown = passwordResetCooldown else {
                return
            }
            if let notice = cooldown.notice(at: now()) {
                sendPasswordResetLinkError = notice.resetErrorMessage
            } else {
                passwordResetCooldown = nil
                sendPasswordResetLinkError = nil
            }
        }
        
        // A request error is a failure. Otherwise the notice for the server's
        // answer; only `sent` means the link was sent.
        func sendPasswordResetLink(_ userAuth: String) async -> Result<VerifySendNotice, Error> {
            
            if !passwordResetEnabled {
                return .failure(SendPasswordResetLinkError.isSending)
            }
            
            self.isSendingPasswordResetLink = true
            self.sendPasswordResetLinkError = nil

            let (outcome, retryAfterSeconds): (Result<VerifySendNotice, Error>, Int) = await withCheckedContinuation { continuation in
                
                let callback = AuthPasswordResetCallback { result, err in
                    continuation.resume(returning: (
                        passwordResetOutcome(result: result, err: err),
                        result?.error?.retryAfterSeconds ?? 0
                    ))
                }
                
                api.authPasswordReset(passwordResetArgs(userAuth: userAuth), callback: callback)
                
            }
            
            self.isSendingPasswordResetLink = false
            if case .success(let notice) = outcome {
                applyPasswordResetNotice(notice, retryAfterSeconds: retryAfterSeconds)
            }
            return outcome
            
        }
        
        func applyPasswordResetNotice(_ notice: VerifySendNotice, retryAfterSeconds: Int) {
            passwordResetCooldown = SendCooldown.after(notice, retryAfterSeconds: retryAfterSeconds, now: now())
            sendPasswordResetLinkError = notice.resetErrorMessage
        }
        
        func startEditingNetworkName(currentName: String) {
            editedNetworkName = currentName
            isEditingNetworkName = true
            networkNameError = nil
        }
        
        func saveNetworkName() async -> Result<String, Error> {
            
            let name = editedNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .failure(NetworkNameError.empty)
            }
            
            isSavingNetworkName = true
            networkNameError = nil
            
            do {
                let result: SdkChangeNetworkNameResult = try await withCheckedThrowingContinuation { continuation in
                    
                    let callback = ChangeNetworkNameCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: NetworkNameError.resultNil)
                            return
                        }
                        
                        if let errMsg = result.error?.message {
                            continuation.resume(throwing: NSError(domain: "ProfileViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                            return
                        }
                        
                        continuation.resume(returning: result)
                    }
                    
                    let args = SdkChangeNetworkNameArgs()
                    args.newName = name
                    api.changeNetworkName(args, callback: callback)
                }
                
                self.isSavingNetworkName = false
                self.isEditingNetworkName = false
                return .success(result.networkName)
                
            } catch(let error) {
                self.isSavingNetworkName = false
                self.networkNameError = error.localizedDescription
                return .failure(error)
            }
        }
        
        func claimNetworkName() async -> Result<String, Error> {
            
            let name = editedNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .failure(NetworkNameError.empty)
            }
            
            isSavingNetworkName = true
            networkNameError = nil
            
            do {
                let result: SdkClaimNetworkNameResult = try await withCheckedThrowingContinuation { continuation in
                    
                    let callback = ClaimNetworkNameCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: NetworkNameError.resultNil)
                            return
                        }
                        
                        if let errMsg = result.error?.message {
                            continuation.resume(throwing: NSError(domain: "ProfileViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                            return
                        }
                        
                        continuation.resume(returning: result)
                    }
                    
                    let args = SdkClaimNetworkNameArgs()
                    args.newName = name
                    api.claimNetworkName(args, callback: callback)
                }
                
                self.isSavingNetworkName = false
                self.isEditingNetworkName = false
                return .success(result.networkName)
                
            } catch(let error) {
                self.isSavingNetworkName = false
                self.networkNameError = error.localizedDescription
                return .failure(error)
            }
        }
        
        func cancelEditingNetworkName() {
            isEditingNetworkName = false
            editedNetworkName = ""
            networkNameError = nil
        }
        
    }
    
}

enum SendPasswordResetLinkError: Error {
    case isSending
    case resultInvalid
}

enum NetworkNameError: Error {
    case empty
    case resultNil
}

private class AuthPasswordResetCallback: SdkCallback<SdkAuthPasswordResetResult, SdkAuthPasswordResetCallbackProtocol>, SdkAuthPasswordResetCallbackProtocol {
    func result(_ result: SdkAuthPasswordResetResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ChangeNetworkNameCallback: SdkCallback<SdkChangeNetworkNameResult, SdkChangeNetworkNameCallbackProtocol>, SdkChangeNetworkNameCallbackProtocol {
    func result(_ result: SdkChangeNetworkNameResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ClaimNetworkNameCallback: SdkCallback<SdkClaimNetworkNameResult, SdkClaimNetworkNameCallbackProtocol>, SdkClaimNetworkNameCallbackProtocol {
    func result(_ result: SdkClaimNetworkNameResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
