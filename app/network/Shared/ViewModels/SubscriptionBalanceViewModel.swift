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

    /**
     * The upgrade-confirmation poll has a DEADLINE.
     *
     * A purchase reaches our server asynchronously (the App Store notifies it by
     * webhook), so right after StoreKit reports success the server does not know yet.
     * We poll to bridge that gap -- that part works.
     *
     * But a webhook can be lost or badly delayed, and the poll only ever stopped on
     * SUCCESS. So in that case it ran every 5 seconds for the rest of the session,
     * behind a spinner, with no way for the user to learn anything had gone wrong.
     * They paid, and the app just span. Give up after `maxPollingDuration` and say so.
     */
    private var pollingDeadline: Date?
    private let maxPollingDuration: TimeInterval = 120.0 // 2 minutes

    /**
     * True when the confirmation poll gave up without the server ever confirming Pro.
     * StoreKit took the money but we could not verify the entitlement, so the UI must
     * SAY that -- it is the difference between "we're still working on it" and an
     * endless spinner.
     */
    @Published private(set) var purchaseConfirmationTimedOut: Bool = false
    
    // this is used primarily for the data usage bar
    private var backgroundPollingTimer: Timer?
    private var backgroundPollingInterval: TimeInterval = 30.0 // 30 seconds
    private var active = false
    
    @Published private(set) var usedBalanceByteCount: Int = 0
    @Published private(set) var pendingByteCount: Int = 0
    @Published private(set) var availableByteCount: Int = 0
    @Published private(set) var startBalanceByteCount: Int = 0
    
    private let refreshJwt: () -> Void
    private var isPro: Bool

    // the last balance published for the Home Screen dashboard, so the
    // 30 s poll only rewrites the snapshot (and reloads the widget) on change
    private var lastWidgetBalanceSnapshot: WidgetBalanceSnapshot?

    // set once when a free -> paid upgrade is first detected, so the app can
    // reset provide mode to never at the upgrade (the user can opt back in after)
    @Published private(set) var didDetectUpgradeToPro: Bool = false


    init(
        urApiService: UrApiServiceProtocol,
        isPro: Bool,
        refreshJwt: @escaping () -> Void
    ) {
        self.urApiService = urApiService
        self.refreshJwt = refreshJwt
        self.isPro = isPro
    }

    deinit {
        pollingTimer?.invalidate()
        backgroundPollingTimer?.invalidate()
    }

    func setActive(_ nextActive: Bool) {
        guard active != nextActive else {
            return
        }
        active = nextActive

        if !active {
            pauseTimers()
            return
        }

        if isPolling {
            resumeConfirmationPolling()
        } else if !isPro {
            startBackgroundPolling()
        }
    }
    
    func updateIsPro(_ isPro: Bool) {
        
        print("updating is pro in SubscriptionBalanceViewModel")
        
        guard isPro != self.isPro else { return }
        self.isPro = isPro

        // If user becomes Pro, stop background polling; if they revert, start it
        if isPro {
            stopPolling()
        } else {
            stopPolling()
            if active {
                startBackgroundPolling()
            }
        }
        
    }
    
    private func setIsPolling(_ isPolling: Bool) {
        self.isPolling = isPolling
    }
    
//    func setCurrentPlan(_ plan: Plan) {
//        self.currentPlan = plan
//    }
    
    func fetchSubscriptionBalance() async {
        
        print("fetchSubscriptionBalance hit. isLoading? \(self.isLoading)")
        
        if self.isLoading { return }
        
        self.isLoading = true
        
        do {
            
            let result = try await urApiService.fetchSubscriptionBalance()
            
            self.availableByteCount = Int(result.balanceByteCount)
            self.pendingByteCount = Int(result.openTransferByteCount)
            self.usedBalanceByteCount = Int(result.startBalanceByteCount) - self.availableByteCount - self.pendingByteCount
            self.startBalanceByteCount = Int(result.startBalanceByteCount)
            
            // The server is the source of truth for Pro, and `currentSubscription` is
            // non-nil exactly when the network is Pro. The jwt's `pro` claim is baked
            // in when the token is issued, so it goes stale on BOTH an upgrade and a
            // lapse. Refresh the jwt whenever the two disagree, in either direction.
            //
            // The downgrade case used to live inside `if let currentSubscription`,
            // which is nil precisely when the user is no longer pro -- so it could
            // never run. A lapsed subscriber kept showing "Supporter", kept Pro
            // behavior, and kept the upgrade CTA hidden until the app was relaunched.
            let serverIsPro = result.currentSubscription != nil

            // the Home Screen dashboard's balance bar reads this snapshot;
            // the tunnel extension refreshes it on its own slow cadence while
            // the tunnel is up, the app whenever it fetches
            let balanceSnapshot = WidgetBalanceSnapshot(
                updatedAt: Date(),
                startBalanceByteCount: result.startBalanceByteCount,
                balanceByteCount: result.balanceByteCount,
                openTransferByteCount: result.openTransferByteCount,
                isPro: serverIsPro
            )
            if balanceSnapshot.usedByteCount != lastWidgetBalanceSnapshot?.usedByteCount
                || balanceSnapshot.balanceByteCount != lastWidgetBalanceSnapshot?.balanceByteCount
                || balanceSnapshot.startBalanceByteCount != lastWidgetBalanceSnapshot?.startBalanceByteCount {
                lastWidgetBalanceSnapshot = balanceSnapshot
                if WidgetSnapshotStore.save(balanceSnapshot) {
                    WidgetRefresh.reloadDashboard()
                }
            }

            if serverIsPro && !self.isPro {
                // free -> paid: signal the upgrade so provide mode resets to never once
                self.didDetectUpgradeToPro = true
            }

            if serverIsPro != self.isPro {
                refreshJwt()
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
        self.pollingInterval = interval
    }
    
    private func startBackgroundPolling() {
        guard active, !isPro, !isPolling, backgroundPollingTimer == nil else {
            return
        }
        Task {
            
            await fetchSubscriptionBalance()
            
            if (self.isSupporterWithBalance()) {
                stopPolling()
                return
            }
            guard active, !isPro, !isPolling, backgroundPollingTimer == nil else {
                return
            }

            backgroundPollingTimer = Timer.scheduledTimer(
                withTimeInterval: backgroundPollingInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active else {
                        return
                    }
                    await self.fetchSubscriptionBalance()

                    if self.isSupporterWithBalance() {
                        self.stopPolling()
                    }
                }
            }
        }
    }
    
    func startPolling(interval: TimeInterval = 5.0) {

        guard !isPolling else { return }

        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil

        // a fresh confirmation attempt: clear any previous give-up, and arm the deadline
        self.purchaseConfirmationTimedOut = false
        self.pollingDeadline = Date().addingTimeInterval(maxPollingDuration)

        self.setPollingInterval(interval)
        self.setIsPolling(true)

        if active {
            resumeConfirmationPolling()
        }
    }

    private func resumeConfirmationPolling() {
        guard active, isPolling, pollingTimer == nil else {
            return
        }
        if isPollingDeadlineExpired() {
            timeOutPurchaseConfirmation()
            return
        }

        Task {

            await fetchSubscriptionBalance()

            if (self.isSupporterWithBalance()) {
                stopPolling()
                return
            }

            guard active, isPolling else {
                return
            }
            if isPollingDeadlineExpired() {
                timeOutPurchaseConfirmation()
                return
            }
            guard pollingTimer == nil else {
                return
            }

            pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.isPolling else {
                        return
                    }
                    await self.fetchSubscriptionBalance()

                    if self.isSupporterWithBalance() {
                        self.stopPolling()
                        return
                    }

                    // the server never confirmed within the window -- stop
                    // hammering the api and tell the user, rather than spinning
                    // for the rest of the session
                    if self.isPollingDeadlineExpired() {
                        self.timeOutPurchaseConfirmation()
                    }
                }
            }
        }
    }

    private func isPollingDeadlineExpired() -> Bool {
        guard let pollingDeadline = self.pollingDeadline else { return false }
        return Date() >= pollingDeadline
    }

    /**
     * Give up waiting for the server to confirm the purchase. The money was taken by
     * StoreKit; we simply could not verify the entitlement in time (a lost or slow
     * App Store webhook). Stop polling and raise the flag so the UI can show a real
     * message -- the purchase is still likely to land, and the background poll and the
     * next app launch will pick it up.
     */
    private func timeOutPurchaseConfirmation() {
        stopPolling()
        purchaseConfirmationTimedOut = true
        if active && !isPro {
            startBackgroundPolling()
        }
    }

    func clearPurchaseConfirmationTimeout() {
        purchaseConfirmationTimedOut = false
    }
    
    func isSupporterWithBalance() -> Bool {
        print("is supporter with balance? pro=\(isPro) availableByteCount=\(self.availableByteCount)")
        return isPro && self.availableByteCount > 0
    }
    
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        pollingDeadline = nil
        isPolling = false
        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil
    }

    private func pauseTimers() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil
    }
    
}

enum Plan: String {
    case supporter = "supporter"
    case none = "none"
}
