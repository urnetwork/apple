//
//  EgressContractStatsViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/08.
//

import Foundation
import URnetworkSdk

@MainActor
class EgressContractStatsViewModel: ObservableObject {
    
    @Published private(set) var latestContractStats: SdkContractStats?
    
    var sub: (any SdkSubProtocol)?
    
    
    init(device: SdkDeviceRemote?) {
        
        print("[EgressContractStatsViewModel] init")
        
        guard let device = device else {
            return
        }
        
        self.sub = device.addEgressContratStatsChangeListener(ContractStatsChangeListener { [weak self] stats in
            
            guard let self = self else { return }
            
            print("[EgressContractStatsViewModel] status updated: \(String(describing: stats))")
            
            self.latestContractStats = stats
            
        })
        
    }
    
    deinit {
        print("[EgressContractStatsViewModel] deinit")
        self.sub?.close()
    }
    
}

private class ContractStatsChangeListener: NSObject, SdkContractStatsChangeListenerProtocol {
    
    private let c: (_ stats: SdkContractStats?) -> Void

    init(c: @escaping (_ stats: SdkContractStats?) -> Void) {
        self.c = c
    }
    
    func contractStatsChanged(_ contractStats: SdkContractStats?) {
        self.c(contractStats)
    }
    
}
