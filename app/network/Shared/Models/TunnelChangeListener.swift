//
//  TunnelChangeListener.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/27.
//

import Foundation
import URnetworkSdk

class TunnelChangeListener: NSObject, SdkTunnelChangeListenerProtocol {
    
    private let c: (_ tunnelStarted: Bool) -> Void

    init(c: @escaping (_ tunnelStarted: Bool) -> Void) {
        self.c = c
    }
    
    func tunnelChanged(_ tunnelStarted: Bool) {
        c(tunnelStarted)
    }
}
