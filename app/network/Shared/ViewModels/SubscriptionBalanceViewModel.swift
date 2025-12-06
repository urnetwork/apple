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
    @Published private(set) var errorFetchingSubscriptionBalance: Bool = false

    /**
     * polling
     */
    // when the user has updated, we want to poll to check their balance + subscription have been bumped
    @Published private(set) var isPolling: Bool = false
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 5.0 // Default 5 seconds
    
    // this is used primarily for the data usage bar
    private var backgroundPollingTimer: Timer?
    private var backgroundPollingInterval: TimeInterval = 30.0 // 30 seconds
    
    @Published private(set) var usedBalanceByteCount: Int = 0
    @Published private(set) var pendingByteCount: Int = 0
    @Published private(set) var availableByteCount: Int = 0
    
    @Published private(set) var currentPlan: Plan = .none
    
    
    init(urApiService: UrApiServiceProtocol) {
        self.urApiService = urApiService
        
//        Task {
//            // await fetchSubscriptionBalance()
//            startBackgroundPolling()
//        }
  
        startBackgroundPolling()
        
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
        
        if self.isLoading { return }
        
        self.isLoading = true
        
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
            self.errorFetchingSubscriptionBalance = false
            
            
        } catch(let error) {
            print("\(domain) error fetching payouts \(error)")
            self.isLoading = false
            self.errorFetchingSubscriptionBalance = true
        }
        
    }
    
    func setPollingInterval(_ interval: TimeInterval) {
        DispatchQueue.main.async {
            self.pollingInterval = interval
        }
    }
    
    private func startBackgroundPolling() {
        Task {
            
            await fetchSubscriptionBalance()
            
            if (self.isSupporterWithBalance()) {
                stopPolling()
                return
            }
            
            // Set up timer for subsequent fetches
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // poll every 30 seconds
                self.backgroundPollingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
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
        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil
    }
    
}

enum Plan: String {
    case supporter = "supporter"
    case none = "none"
}
