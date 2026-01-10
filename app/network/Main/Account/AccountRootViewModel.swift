//
//  AccountViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/13.
//

import Foundation
import URnetworkSdk

extension AccountRootView {
    
    class ViewModel: ObservableObject {
        // var api: SdkBringYourApi
        
        @Published var isPresentedUpgradeSheet: Bool = false
        @Published var isPresentedCreateAccount: Bool = false
        @Published var isPresentedRedeemBalanceCodeSheet: Bool = false
        @Published var balanceCodeRedeemed: Bool = false
        
//        init(api: SdkBringYourApi) {
//            self.api = api
//        }
    }
    
}

