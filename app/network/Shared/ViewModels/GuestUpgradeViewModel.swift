//
//  GuestUpgradeViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/19.
//

import Foundation
import URnetworkSdk

@MainActor
class GuestUpgradeViewModel: ObservableObject {
    
    @Published private(set) var isUpgrading: Bool = false
    
    private var api: SdkApi
    
    let domain = "[GuestUpgradeViewModel]"
    
    init(api: SdkApi) {
        self.api = api
    }
    
    func linkGuestToExistingLogin(args: SdkUpgradeGuestExistingArgs) async -> AuthLoginResult {
        
        do {
            
            let result: AuthLoginResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = UpgradeGuestExistingCallback { [weak self] result, error in
                    
                    guard let self = self else { return }
                    
                    guard let result else {
                        
                        continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "No result found"]))
                        
                        return
                    }
                    
                    if let resultError = result.error {
                        
                        continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "result.error exists \(resultError.message)"]))
                        
                        return
                    }
                    
                    /**
                     * In the case a guest user is upgrading to an existing account
                     * but the existing account has not yet been verified
                     */
                    if let verificationRequired = result.verificationRequired {
                        continuation.resume(returning: .verificationRequired(verificationRequired.userAuth))
                        return
                    }
                    
                    /**
                     * JWT exists, proceed to authenticate network
                     */
                    if let jwt = result.network?.byJwt {
                        continuation.resume(returning: .login(jwt))
                        return
                    }
                    
                    /**
                     * No network exists
                     * Navigate to create view
                     */
                    let authLoginArgs = SdkAuthLoginArgs()
                    
                    authLoginArgs.authJwt = args.authJwt
                    authLoginArgs.authJwtType = args.authJwtType
                    authLoginArgs.userAuth = args.userAuth
                    authLoginArgs.walletAuth = args.walletAuth
                    

                    continuation.resume(returning: .create(authLoginArgs))
                    
                    
                }
                
                api.upgradeGuestExisting(args, callback: callback)
                
            }
            
            return result
            
        } catch(let error) {
            return .failure(error)
        }
        
    }
    
}

private class UpgradeGuestExistingCallback: SdkCallback<SdkUpgradeGuestExistingResult, SdkUpgradeGuestExistingCallbackProtocol>, SdkUpgradeGuestExistingCallbackProtocol {
    func result(_ result: SdkUpgradeGuestExistingResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
