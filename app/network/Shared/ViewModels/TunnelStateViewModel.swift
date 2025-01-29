//
//  TunnelStateViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/29.
//

import Foundation
import URnetworkSdk

@MainActor
class TunnelStateViewModel: ObservableObject {
    
    var device: SdkDeviceRemote
    
    @Published private(set) var tunnelConnected: Bool = false
    
    
    
    init(device: SdkDeviceRemote) {
        self.device = device
        
        let tunnelListener = TunnelChangeListener { [weak self] (tunnelConnected: Bool) in
            
            guard let self = self else { return }
            
            print("tunnel connected? \(tunnelConnected)")
            
            DispatchQueue.main.async {
                self.tunnelConnected = tunnelConnected
            }
            
        }
        
        device.add(tunnelListener)
        
    }
    
    deinit {
        
    }
    
    private class TunnelChangeListener: NSObject, SdkTunnelChangeListenerProtocol {
        func tunnelChanged(_ tunnelConnected: Bool) {
            c(tunnelConnected)
        }

        private let c: (_ tunnelConnected: Bool) -> Void

        init(callback: @escaping (_ tunnelConnected: Bool) -> Void) {
            self.c = callback
        }
        
    }
    
    
}
