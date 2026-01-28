//
//  RedeemBalanceCodeSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/9/26.
//

import Foundation
import URnetworkSdk


extension RedeemBalanceCodeSheet {
    
    enum RedeemBalanceCodeError: Error {
        case inProgress
        case unknown(String)
    }
    
    @MainActor
    class ViewModel: ObservableObject {
        
//        @Published var isProcessing: Bool = false
        @Published var code: String = ""
//        @Published var codeInvalid: Bool = false
        @Published var redeemState: ValidationState = .notChecked
        
        let domain = "[RedeemBalanceCodeSheetViewModel]"
        
        let api: UrApiServiceProtocol
        
        init(api: UrApiServiceProtocol) {
            self.api = api
        }
        
        func redeem() async -> Result<Void, Error> {
  
            if self.redeemState == .validating {
                return .failure(RedeemBalanceCodeError.inProgress)
            }
            
            self.redeemState = .validating
            
//            if isProcessing {
//                return .failure(RedeemBalanceCodeError.inProgress)
//            }

//            isProcessing = true
//            codeInvalid = false

            do {

                let result = try await api.redeemBalanceCode(self.code)
                
//                isProcessing = false
                
                if result.error != nil {
                    self.redeemState = .invalid
//                    codeInvalid = true
                    return .failure(RedeemBalanceCodeError.unknown(result.error?.message ?? "An unknown error occurred redeeming the balance code"))
                }
                
                self.redeemState = .valid
                return .success(())

            } catch(let error) {
                print("\(domain) Error redeeming balance code: \(error)")
                self.redeemState = .invalid
//                isProcessing = false
//                codeInvalid = true
                return .failure(error)
            }
            
        }
        
    }
    
}
