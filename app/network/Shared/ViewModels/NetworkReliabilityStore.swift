//
//  NetworkReliabilityViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/26/25.
//

import Foundation
import URnetworkSdk

@MainActor
class NetworkReliabilityStore: ObservableObject {
    
    let api: UrApiServiceProtocol
    @Published private(set) var isFetchingReliabilityWindow = false
    @Published private(set) var reliabilityWindow: SdkReliabilityWindow?
    
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 60.0 // poll every minute
    
    init(api: UrApiServiceProtocol) {
        self.api = api
        
        startPolling()
    }
    
    private func startPolling() {
        Task {
            
            await getNetworkReliability()
            
            // Set up timer for subsequent fetches
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // poll every minute
                self.pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    
                    Task {
                        await self.getNetworkReliability()
                    }
                }
            }
        }
    }
    
    func getNetworkReliability() async {
        
        if (isFetchingReliabilityWindow) {
            return
        }
        
        isFetchingReliabilityWindow = true
        
        do {
            let result = try await api.getNetworkReliability()
            
            if result.error != nil {
                return
            }
            
            reliabilityWindow = result.reliabilityWindow
            
            isFetchingReliabilityWindow = false
        } catch (let error) {
            print("Error fetching reliability window: \(error)")
            isFetchingReliabilityWindow = false
        }
        
    }
    
}
