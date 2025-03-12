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
    
    private var api: SdkApi?
    let domain = "[SubscriptionBalanceViewModel]"
    
    @Published private(set) var isLoading: Bool = false
    
    // @Published private(set) var currentSubscription: SdkSubscription?
    @Published private(set) var currentPlan: Plan = .none
    
    init(api: SdkApi? = nil) {
        self.api = api
        
        Task {
            await fetchSubscriptionBalance()
        }
        
    }
    
    func setCurrentPlan(_ plan: Plan) {
        self.currentPlan = plan
    }
    
    func fetchSubscriptionBalance() async {
        
        if isLoading { return }
        
        isLoading = true
        
        do {
            
            let result: SdkSubscriptionBalanceResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = GetSubscriptionBalanceCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "GetSubscriptionBalanceCallback result is nil"]))
                        return
                    }
                    
                    continuation.resume(returning: result)
                    
                }
                
                api?.subscriptionBalance(callback)
            }
            
            
            DispatchQueue.main.async {
                
                if let currentSubscription = result.currentSubscription {
                 
                    if let validPlan = Plan(rawValue: currentSubscription.plan.lowercased()) {
                        self.setCurrentPlan(validPlan)
                    } else {
                        self.setCurrentPlan(.none)
                    }
                    
                } else {
                    self.setCurrentPlan(.none)
                }
                
                print("current plan is: \(self.currentPlan)")
                
                self.isLoading = false
            }
            
        } catch(let error) {
            print("\(domain) error fetching payouts \(error)")
            self.isLoading = false
        }
        
    }
    
}

enum Plan: String {
    case supporter = "supporter"
    case none = "none"
}

private class GetSubscriptionBalanceCallback: SdkCallback<SdkSubscriptionBalanceResult, SdkSubscriptionBalanceCallbackProtocol>, SdkSubscriptionBalanceCallbackProtocol {
    
    func result(_ result: SdkSubscriptionBalanceResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
