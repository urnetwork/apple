//
//  TransferBalanceCodesViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/17/26.
//

import Foundation
import URnetworkSdk

extension TransferBalanceCodesView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        let api: UrApiServiceProtocol
        @Published private(set) var isLoading: Bool = false
        @Published var displayRedeemSheet: Bool = false
        @Published private(set) var isInitializing: Bool = true
        @Published private(set) var redeemedBalanceCodes: [SdkRedeemedBalanceCode] = []
        
        init(
            api: UrApiServiceProtocol
        ) {
            self.api = api
            
            Task {
                await self.getRedeemedBalanceCodes()
                self.isInitializing = false
            }
        }
        
        func getRedeemedBalanceCodes() async {
            
            if (isLoading) {
                return
            }
            
            isLoading = true
            
            do {

                let result = try await api.getRedeemedBalanceCodes()

                let len = result.balanceCodes?.len() ?? 0
                var balanceCodes: [SdkRedeemedBalanceCode] = []

                if len > 0 {

                    // loop
                    for i in 0..<len {
                        
                        if let location = result.balanceCodes?.get(i) {
                            balanceCodes.append(location)
                        }
                    }
                }
                
                self.redeemedBalanceCodes = balanceCodes
                self.isLoading = false
                
            } catch (let error) {
                print("error fetching redeemed balance codes: \(error)")
                self.isLoading = false
            }
            
        }
        
    }
    
}
