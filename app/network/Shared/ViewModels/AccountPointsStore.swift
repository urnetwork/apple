//
//  AccountPointsViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/05/29.
//

import Foundation
import URnetworkSdk

@MainActor
class AccountPointsStore: ObservableObject {
    
    var api: SdkApi?
    @Published private(set) var accountPoints: [SdkAccountPoint] = []
    
    @Published private(set) var netPoints: Double = 0
    @Published private(set) var providingPoints: Double = 0
    @Published private(set) var multiplierPoints: Double = 0
    @Published private(set) var referralPoints: Double = 0
    @Published private(set) var reliabilityPoints: Double = 0
    
    @Published private(set) var isLoading: Bool = false
    
    
    init(api: SdkApi?) {
        self.api = api
        
        Task {
            await fetchAccountPoints()
        }
        
    }
    
    func netPointsByPaymentId(_ paymentId: SdkId?) -> Double {
        accountPoints
            .filter { $0.accountPaymentId?.cmp(paymentId) == 0}
            .reduce(into: 0) { $0 += SdkNanoPointsToPoints($1.pointValue) }
    }
    
    // for example, all reliability points for this payment
    func sumEventPointsByPaymentId(event: AccountPointEvent, paymentId: SdkId?) -> Double {
        accountPoints
            .filter { $0.accountPaymentId?.cmp(paymentId) == 0}
            .filter { $0.event == event.rawValue }
            .reduce(into: 0) { $0 += SdkNanoPointsToPoints($1.pointValue) }
    }
    
    
    func fetchAccountPoints() async {
        
        if (isLoading) {
            return
        }
        
        self.isLoading = true
        
        do {
            
            let result: SdkAccountPointsResult = try await withCheckedThrowingContinuation { continuation in
                
                let callback = GetAccountPointsCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: GetAccountPointsError.resultEmpty)
                        return
                    }
                    
                    continuation.resume(returning: result)
                    
                }
                
                guard let api = self.api else {
                    continuation.resume(throwing: GetAccountPointsError.resultEmpty)
                    return
                }
                api.getAccountPoints(callback)
            }
            
            let n = result.accountPoints?.len()
            
            var netPoints = 0.0
            var providingPoints = 0.0
            var multiplierPoints = 0.0
            var referralPoints = 0.0
            var reliabilityPoints = 0.0
            var accountPoints: [SdkAccountPoint] = []
            
            guard let n = n else {
                self.isLoading = false
                return
            }
            
            for i in 0..<n {
                let accountPoint = result.accountPoints?.get(i)

                if let accountPoint = accountPoint {
                    
                    let pointValue = SdkNanoPointsToPoints(accountPoint.pointValue)
                    
                    netPoints += pointValue
                    accountPoints.append(accountPoint)
                    
                    if let event = AccountPointEvent(rawValue: accountPoint.event) {
                        
                        switch event {
                            case .payout:
                                providingPoints += pointValue
                            case .payoutLinkedAccount:
                                referralPoints += pointValue
                            case .payoutMultiplier:
                                multiplierPoints += pointValue
                            case .payoutReliability:
                                reliabilityPoints += pointValue
                        }
                        
                    } else {
                        print("Invalid event string: \(accountPoint.event)")
                    }
                    
                }
            }
            
            self.accountPoints = accountPoints
            self.netPoints = netPoints
            
            self.providingPoints = providingPoints
            self.referralPoints = referralPoints
            self.multiplierPoints = multiplierPoints
            self.reliabilityPoints = reliabilityPoints
            
            self.isLoading = false
            
        } catch(let error) {
            print("error fetching account points \(error)")
            self.isLoading = false
        }
        
    }
    
}

private class GetAccountPointsCallback: SdkCallback<SdkAccountPointsResult, SdkGetAccountPointsCallbackProtocol>, SdkGetAccountPointsCallbackProtocol {
    func result(_ result: SdkAccountPointsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum GetAccountPointsError: Error {
    case resultError(message: String)
    case resultEmpty
    case unknown
}

enum AccountPointEvent: String {
    case payout = "payout"
    case payoutLinkedAccount = "payout_linked_account"
    case payoutMultiplier = "payout_multiplier"
    case payoutReliability = "payout_reliability"
}
