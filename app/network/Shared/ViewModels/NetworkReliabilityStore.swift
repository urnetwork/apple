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
    
    init(api: UrApiServiceProtocol) {
        self.api = api
        
        Task {
            await getNetworkReliability()
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
