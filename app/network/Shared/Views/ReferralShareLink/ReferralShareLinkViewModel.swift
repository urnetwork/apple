//
//  ReferSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/03.
//

import Foundation
import URnetworkSdk

/**
 * A batch of newly observed referrals for the local network. `isFirst` marks
 * the crowning: the count went from zero to earned, which gets the full-screen
 * celebration; later batches get the gold snackbar.
 */
struct ReferralCelebration: Equatable {
    let joined: Int
    let isFirst: Bool
}

@MainActor
class ReferralLinkViewModel: ObservableObject {

    @Published private(set) var referralCode: String?
    @Published private(set) var totalReferrals: Int = 0
    @Published private(set) var isLoading: Bool = false

    /**
     * Referral celebrations, keyed off the count the last celebration (or the
     * baseline) left behind, persisted per network (the referral code is
     * stable and unique per network) so an increment observed on this device
     * celebrates exactly once. The first observation only records the
     * baseline: pre-existing referrals (reinstall, second device) are old
     * news, not a surprise.
     */
    @Published private(set) var pendingCelebration: ReferralCelebration?

    func clearCelebration() {
        pendingCelebration = nil
    }

    private func maybeCelebrate(code: String, count: Int) {
        guard !code.isEmpty else { return }

        let defaults = UserDefaults.standard
        let key = "referral.celebratedCount.\(code)"

        guard defaults.object(forKey: key) != nil else {
            // first observation for this network on this device: baseline only
            defaults.set(count, forKey: key)
            return
        }

        let previous = defaults.integer(forKey: key)
        if count > previous {
            if let pending = pendingCelebration {
                // an unseen celebration is still up: fold the new arrivals in
                pendingCelebration = ReferralCelebration(
                    joined: pending.joined + (count - previous),
                    isFirst: pending.isFirst
                )
            } else {
                pendingCelebration = ReferralCelebration(
                    joined: count - previous,
                    isFirst: previous == 0
                )
            }
            defaults.set(count, forKey: key)
        } else if count < previous {
            // referrals can be unlinked; re-baseline quietly
            defaults.set(count, forKey: key)
        }
    }

    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 60.0 // poll every minute
    private var active = false

    let domain = "ReferralLinkViewModel"

    let api: SdkApi?

    init(api: SdkApi) {
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
            
            await fetchReferralLink()
            guard active, pollingTimer == nil else {
                return
            }
            
            // Set up timer for subsequent fetches
            pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active else {
                        return
                    }
                    await self.fetchReferralLink()
                }
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    func fetchReferralLink() async {
        
        if isLoading {
            return
        }
        
        self.isLoading = true
        
        do {
            
            let result: SdkGetNetworkReferralCodeResult = try await withCheckedThrowingContinuation { continuation in
                
                let callback = GetNetworkReferralCodeCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    if let result = result {
                        
                        if let resultErr = result.error {
                            continuation.resume(throwing: NSError(domain: "ReferralLinkViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: resultErr.message]))
                            return
                        }
                        
                        continuation.resume(returning: result)
                        return
                        
                    } else {
                        continuation.resume(throwing: NSError(domain: "ReferralLinkViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "result is nil"]))
                    }
                }
                
                api?.getNetworkReferralCode(callback)
            }
            
            
            self.referralCode = result.referralCode
            self.totalReferrals = result.totalReferrals
            self.isLoading = false

            self.maybeCelebrate(code: result.referralCode, count: result.totalReferrals)

        } catch(let error) {
            self.isLoading = false
            print("error fetching referral link: \(error.localizedDescription)")
        }
        
    }
    
}

private class GetNetworkReferralCodeCallback: SdkCallback<SdkGetNetworkReferralCodeResult, SdkGetNetworkReferralCodeCallbackProtocol>, SdkGetNetworkReferralCodeCallbackProtocol {
    func result(_ result: SdkGetNetworkReferralCodeResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
