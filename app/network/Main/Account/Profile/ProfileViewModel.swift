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
        
        @Published var isEditingNetworkName: Bool = false
        @Published var editedNetworkName: String = ""
        @Published private(set) var isSavingNetworkName: Bool = false
        @Published private(set) var networkNameError: String?
        
        init(api: SdkApi) {
            self.api = api
        }
        
        func sendPasswordResetLink(_ userAuth: String) async -> Result<Void, Error> {
            
            if isSendingPasswordResetLink {
                return .failure(SendPasswordResetLinkError.isSending)
            }
            
            self.isSendingPasswordResetLink = true

            do {

                let _: SdkAuthPasswordResetResult = try await withCheckedThrowingContinuation { continuation in
                    
                    let callback = AuthPasswordResetCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: SendPasswordResetLinkError.resultInvalid)
                            return
                        }
                        
                        continuation.resume(returning: result)
                        
                    }
                    
                    let args = SdkAuthPasswordResetArgs()
                    args.userAuth = userAuth
                    
                    api.authPasswordReset(args, callback: callback)
                    
                }
                   
                self.isSendingPasswordResetLink = false

                return .success(())

            }
            catch(let error) {
                self.isSendingPasswordResetLink = false
                return .failure(error)
            }

            
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
