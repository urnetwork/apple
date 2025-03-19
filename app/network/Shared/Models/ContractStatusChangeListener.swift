//
//  ContractStatusChangeListener.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/18.
//

import Foundation
import URnetworkSdk

class ContractStatusChangeListener: NSObject, SdkContractStatusChangeListenerProtocol {
    
    private let c: (_ contractStatus: SdkContractStatus?) -> Void

    init(c: @escaping (_ contractStatus: SdkContractStatus?) -> Void) {
        self.c = c
    }
    
    func contractStatusChanged(_ contractStatus: SdkContractStatus?) {
        c(contractStatus)
    }
}
