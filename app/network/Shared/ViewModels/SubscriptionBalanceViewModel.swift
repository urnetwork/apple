//
//  SubscriptionManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/12.
//

import Foundation
import URnetworkSdk

/**
 * For pulling user subscription data from our DB
 */

@MainActor
class SubscriptionBalanceViewModel: ObservableObject {
    
    private let urApiService: UrApiServiceProtocol
    let domain = "[SubscriptionBalanceViewModel]"
    
    @Published private(set) var isLoading: Bool = false

    /**
     * polling
     */
    @Published private(set) var isPolling: Bool = false
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 5.0 // Default 5 seconds
    
    @Published private(set) var usedBalanceByteCount: Int = 0
    @Published private(set) var pendingByteCount: Int = 0
    @Published private(set) var availableByteCount: Int = 0
    
    @Published private(set) var currentPlan: Plan = .none
    
    
    init(urApiService: UrApiServiceProtocol) {
        self.urApiService = urApiService
        
        Task {
            await fetchSubscriptionBalance()
        }
        
    }
    
    private func setIsPolling(_ isPolling: Bool) {
        DispatchQueue.main.async {
            self.isPolling = isPolling
        }
    }
    
    func setCurrentPlan(_ plan: Plan) {
        self.currentPlan = plan
    }
    
    func fetchSubscriptionBalance() async {
        
        if isLoading { return }
        
        isLoading = true
        
        do {
            
            let result = try await urApiService.fetchSubscriptionBalance()
            
            self.availableByteCount = Int(result.balanceByteCount)
            self.pendingByteCount = Int(result.openTransferByteCount)
            self.usedBalanceByteCount = Int(result.startBalanceByteCount) - self.availableByteCount - self.pendingByteCount
            
            if let currentSubscription = result.currentSubscription {
             
                if let validPlan = Plan(rawValue: currentSubscription.plan.lowercased()) {
                    self.setCurrentPlan(validPlan)
                } else {
                    self.setCurrentPlan(.none)
                }
                
            } else {
                self.setCurrentPlan(.none)
            }
            
            self.isLoading = false
            
            
        } catch(let error) {
            print("\(domain) error fetching payouts \(error)")
            self.isLoading = false
        }
        
    }
    
    func setPollingInterval(_ interval: TimeInterval) {
        DispatchQueue.main.async {
            self.pollingInterval = interval
        }
    }
    
    func startPolling(interval: TimeInterval = 5.0) {
        
        guard !isPolling else { return }
        
        // Perform initial fetch
        Task {
            
            self.setPollingInterval(interval)
            self.setIsPolling(true)
            
            await fetchSubscriptionBalance()
            
            if (self.isSupporterWithBalance()) {
                stopPolling()
                return
            }
            
            // Set up timer for subsequent fetches
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    
                    Task {
                        await self.fetchSubscriptionBalance()
                        
                        if (await self.isSupporterWithBalance()) {
                            await self.stopPolling()
                        }
                        
                    }
                }
            }
        }
    }
    
    func isSupporterWithBalance() -> Bool {
        return self.currentPlan == .supporter && self.availableByteCount > 0
    }
    
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isPolling = false
    }
    
}

enum Plan: String {
    case supporter = "supporter"
    case none = "none"
}
