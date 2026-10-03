//
//  RedeemBalanceCodeSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/9/26.
//

import Foundation
import URnetworkSdk

/**
 * A credited redeem: the data the code added to the network's balance, from the
 * server's answer (transfer_balance.balance_byte_count).
 *
 * A balance code is data only. The server grants its transfer balance with
 * pro = false (RedeemBalanceCodeInTx) and the answer has no Pro field, so a
 * redeem is confirmed as data added (BalanceCodeRedeemedView), never as a Pro
 * upgrade, and the balance is read once rather than through the Pro
 * confirmation poll.
 */
struct RedeemedBalanceCode: Equatable {
    let addedByteCount: Int64

    init(addedByteCount: Int64) {
        self.addedByteCount = addedByteCount
    }

    init(result: SdkRedeemBalanceCodeResult) {
        self.addedByteCount = result.transferBalance?.balanceByteCount ?? 0
    }
}


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
        
        func redeem() async -> Result<RedeemedBalanceCode, Error> {
  
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
                return .success(RedeemedBalanceCode(result: result))

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
