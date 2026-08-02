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
    private var active = false
    
    init(api: UrApiServiceProtocol) {
        self.api = api
    }

    deinit {
        pollingTimer?.invalidate()
    }

    func setActive(_ nextActive: Bool) {
        guard active != nextActive else {
            return
        }
        active = nextActive
        if active {
            startPolling()
        } else {
            stopPolling()
        }
    }
    
    private func startPolling() {
        guard active, pollingTimer == nil else {
            return
        }
        Task {
            
            await getNetworkReliability()
            guard active, pollingTimer == nil else {
                return
            }
            
            // Set up timer for subsequent fetches
            pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active else {
                        return
                    }
                    await self.getNetworkReliability()
                }
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    func getNetworkReliability() async {
        
        if (isFetchingReliabilityWindow) {
            return
        }
        
        isFetchingReliabilityWindow = true
        
        do {
            let result = try await api.getNetworkReliability()
            
            if result.error != nil {
                isFetchingReliabilityWindow = false
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
