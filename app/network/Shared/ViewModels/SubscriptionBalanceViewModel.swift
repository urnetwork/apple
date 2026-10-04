//
//  SubscriptionManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/12.
//

import Foundation
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif
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

    /**
     * The post-purchase confirmation poll runs on the SDK's
     * SubscriptionBalanceViewController (finding A2): 5 s polls against a
     * 120 s polling BUDGET that is paused while the app is inactive, ending in
     * a terminal confirmed / gave-up state.
     *
     * The app used to run its own poll with a wall-clock 120 s deadline that
     * kept running while the app was inactive. A buyer who left the app during
     * checkout (an SCA step, the App Store's own sheets) came back to "we
     * couldn't confirm your purchase" without a single poll having run.
     */
    private let purchaseConfirmation: PurchaseConfirming

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

    /**
     * The server's `guest`: the network has no login method (a legacy guest).
     * Unlike the jwt's guest_mode claim, which every token refresh clears, this
     * is read from the live auth methods. See GuestAccount.isGuest.
     */
    @Published private(set) var isGuest: Bool = false
    
    private let refreshJwt: () -> Void
    private var isPro: Bool

    // the last balance published for the Home Screen dashboard, so the
    // 30 s poll only rewrites the snapshot (and reloads the widget) on change
    private var lastWidgetBalanceSnapshot: WidgetBalanceSnapshot?

    /**
     * The plan data the server sends with the balance: the price tier resolved
     * for this storefront, the welcome offer (only while active), and the
     * experiment assignments. Every plan surface renders from these.
     */
    @Published private(set) var priceTier: PlanTier?
    @Published private(set) var onboardingOffer: PlanOffer?
    @Published private(set) var experimentVariants: [String: String] = [:]
    @Published private(set) var experimentIds: [String: String] = [:]
    /// The App Store storefront's country, read once from StoreKit and sent
    /// with every balance request so the tier follows the store's territory.
    private(set) var storefrontCountry: String?
    private var storefrontResolved = false

    /// The in-app offer surface's assignment: the intro plan step and the
    /// final offer screen show the welcome offer unless the network is in the
    /// holdout, or the server has not assigned it at all.
    var offerScreenEnabled: Bool {
        guard let variant = experimentVariants[SdkExperimentSurfaceOfferInApp] else { return false }
        return variant != "holdout"
    }

    var offerExperimentId: String {
        experimentIds[SdkExperimentSurfaceOfferInApp] ?? ""
    }

    var offerExperimentVariant: String {
        experimentVariants[SdkExperimentSurfaceOfferInApp] ?? ""
    }

    /// The storefront country's name in the user's language, for the regional tier's billing line.
    var storefrontCountryName: String? {
        guard let storefrontCountry else { return nil }
        return Locale.current.localizedString(forRegionCode: storefrontCountry)
    }


    init(
        urApiService: UrApiServiceProtocol,
        isPro: Bool,
        refreshJwt: @escaping () -> Void,
        purchaseConfirmation: PurchaseConfirming
    ) {
        self.urApiService = urApiService
        self.refreshJwt = refreshJwt
        self.isPro = isPro
        self.purchaseConfirmation = purchaseConfirmation
        purchaseConfirmation.setForeground(active)
        purchaseConfirmation.onStateChanged = { [weak self] state in
            self?.purchaseConfirmationStateChanged(state)
        }
    }

    deinit {
        backgroundPollingTimer?.invalidate()
    }

    func setActive(_ nextActive: Bool) {
        guard active != nextActive else {
            return
        }
        active = nextActive
        // the confirmation budget pauses and resumes with the app
        purchaseConfirmation.setForeground(active)

        if !active {
            pauseTimers()
            return
        }

        if !isPolling && !isPro {
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
        if self.isPolling != isPolling {
            self.isPolling = isPolling
        }
    }
    
//    func setCurrentPlan(_ plan: Plan) {
//        self.currentPlan = plan
//    }
    
    private func resolveStorefrontIfNeeded() async {
        guard !storefrontResolved else { return }
        storefrontResolved = true
        // no App Store storefront on the direct-download build: the server
        // resolves the tier from the request
        #if !DIRECT_DOWNLOAD
        if let storefront = await Storefront.current {
            storefrontCountry = storefront.countryCode
        }
        #endif
    }

    /// Reads the tier, the offer and the assignments off a balance result.
    func applyPlanData(_ result: SdkSubscriptionBalanceResult) {
        if let tier = result.priceTier {
            let next = PlanTier(
                name: tier.name,
                yearlyUsd: tier.yearlyUsd,
                monthlyUsd: tier.monthlyUsd,
                isRegional: tier.isRegional()
            )
            if next != priceTier { priceTier = next }
        }
        applyOffer(result.onboardingOffer)
        if let experiments = result.experiments {
            var variants: [String: String] = [:]
            var ids: [String: String] = [:]
            for i in 0..<experiments.len() {
                if let assignment = experiments.get(i) {
                    variants[assignment.surface] = assignment.variant
                    ids[assignment.surface] = assignment.experimentId
                }
            }
            if variants != experimentVariants { experimentVariants = variants }
            if ids != experimentIds { experimentIds = ids }
        }
    }

    private func applyOffer(_ offer: SdkOnboardingOffer?) {
        var next: PlanOffer? = nil
        if let offer, offer.isActive() {
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(offer.expiresAtUnixMillis()) / 1000)
            next = PlanOffer(
                percentOff: offer.percentOff,
                monthsFree: offer.monthsFree,
                expiresAt: expiresAt,
                appleOfferCode: offer.appleOfferCode
            )
        }
        if next != onboardingOffer { onboardingOffer = next }
    }

    /// Issues the welcome offer for this network (the server returns the
    /// existing one on a repeat call) and publishes it. Nothing happens for the
    /// holdout, and a failure leaves the surface without an offer.
    func issueOnboardingOffer(surface: String) async {
        guard offerScreenEnabled || surface == SdkOfferSurfaceAccount else { return }
        if onboardingOffer != nil { return }
        do {
            let offer = try await urApiService.issueOnboardingOffer(surface: surface, storefrontCountry: storefrontCountry)
            applyOffer(offer)
        } catch {
            print("\(domain) error issuing the onboarding offer \(error)")
        }
    }
    
    func fetchSubscriptionBalance() async {
        
        print("fetchSubscriptionBalance hit. isLoading? \(self.isLoading)")
        
        if self.isLoading { return }
        
        self.isLoading = true
        
        do {

            await resolveStorefrontIfNeeded()
            
            let result = try await urApiService.fetchSubscriptionBalance(storefrontCountry: storefrontCountry)

            applyPlanData(result)
            
            self.availableByteCount = Int(result.balanceByteCount)
            self.pendingByteCount = Int(result.openTransferByteCount)
            self.usedBalanceByteCount = Int(result.startBalanceByteCount) - self.availableByteCount - self.pendingByteCount
            self.startBalanceByteCount = Int(result.startBalanceByteCount)
            self.isGuest = result.guest
            
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
            // saved on every fetch, so its time stamp tells the start connect
            // gate how fresh it is; the widgets reload only on a change
            let balanceChanged = balanceSnapshot.usedByteCount != lastWidgetBalanceSnapshot?.usedByteCount
                || balanceSnapshot.balanceByteCount != lastWidgetBalanceSnapshot?.balanceByteCount
                || balanceSnapshot.startBalanceByteCount != lastWidgetBalanceSnapshot?.startBalanceByteCount
            lastWidgetBalanceSnapshot = balanceSnapshot
            if WidgetSnapshotStore.save(balanceSnapshot) && balanceChanged {
                WidgetRefresh.reloadDashboard()
            }

            if serverIsPro != self.isPro {
                refreshJwt()
            }
            
            self.isLoading = false
            self.errorFetchingSubscriptionBalance = false
            
            
        } catch(let error) {
            print("\(domain) error fetching subscription balance \(error)")
            self.isLoading = false
            self.errorFetchingSubscriptionBalance = true
        }
        
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
    
    /**
     * Start the post-purchase confirmation on the SDK controller. The
     * controller is started only for the confirmation (the balance itself is
     * fetched here, with the storefront the plan data needs), and with no
     * loaded snapshot it confirms on Pro with a positive balance, the rule
     * this poll always used.
     */
    func startPolling() {

        guard !isPolling else { return }

        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil

        // a fresh confirmation attempt: clear any previous give-up
        if self.purchaseConfirmationTimedOut {
            self.purchaseConfirmationTimedOut = false
        }
        self.setIsPolling(true)

        // confirmation first, so the controller starts with the budget armed
        // and no baseline snapshot
        purchaseConfirmation.startPurchaseConfirmation()
        purchaseConfirmation.start()
    }

    private func purchaseConfirmationStateChanged(_ state: String) {
        guard isPolling else {
            // a stop (or the idle that follows it) after this view model moved on
            return
        }
        switch state {
        case SdkPurchaseConfirmationStateConfirmed:
            endPurchaseConfirmation()
            // the server reflects the purchase: load it here, which also
            // refreshes the jwt to pro
            Task {
                await fetchSubscriptionBalance()
            }
        case SdkPurchaseConfirmationStateConfirmationGaveUp:
            /**
             * Give up waiting for the server to confirm the purchase. The money was
             * taken by StoreKit; we simply could not verify the entitlement in time (a
             * lost or slow App Store webhook). Raise the flag so the UI can show a real
             * message -- the purchase is still likely to land, and the background poll
             * and the next app launch will pick it up.
             */
            endPurchaseConfirmation()
            if !purchaseConfirmationTimedOut {
                purchaseConfirmationTimedOut = true
            }
            if active && !isPro {
                startBackgroundPolling()
            }
        default:
            break
        }
    }

    private func endPurchaseConfirmation() {
        setIsPolling(false)
        purchaseConfirmation.stop()
    }

    func clearPurchaseConfirmationTimeout() {
        if purchaseConfirmationTimedOut {
            purchaseConfirmationTimedOut = false
        }
    }
    
    func isSupporterWithBalance() -> Bool {
        print("is supporter with balance? pro=\(isPro) availableByteCount=\(self.availableByteCount)")
        return isPro && self.availableByteCount > 0
    }
    
    func stopPolling() {
        if isPolling {
            endPurchaseConfirmation()
        }
        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil
    }

    private func pauseTimers() {
        backgroundPollingTimer?.invalidate()
        backgroundPollingTimer = nil
    }
    
}

/**
 * The purchase-confirmation half of the SDK SubscriptionBalanceViewController,
 * as the view model drives it (a protocol so tests can drive the states).
 * State changes arrive on the main actor.
 */
@MainActor
protocol PurchaseConfirming: AnyObject {
    var onStateChanged: ((String) -> Void)? { get set }
    func start()
    func stop()
    func setForeground(_ foreground: Bool)
    func startPurchaseConfirmation()
}

/**
 * The SDK controller, closed with this object. Its listener fires on a Go
 * thread; states are hopped to the main actor in order.
 */
@MainActor
final class SdkPurchaseConfirmation: PurchaseConfirming {

    var onStateChanged: ((String) -> Void)?

    private let controller: SdkSubscriptionBalanceViewController?
    private var listenerSub: SdkSubProtocol?

    init(api: SdkApi) {
        controller = SdkNewSubscriptionBalanceViewController(api)
        listenerSub = controller?.add(PurchaseConfirmationListener { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onStateChanged?(state)
                }
            }
        })
    }

    func start() {
        controller?.start()
    }

    func stop() {
        controller?.stop()
    }

    func setForeground(_ foreground: Bool) {
        controller?.setForeground(foreground)
    }

    func startPurchaseConfirmation() {
        controller?.startPurchaseConfirmation()
    }

    deinit {
        listenerSub?.close()
        controller?.close()
    }
}

private class PurchaseConfirmationListener: NSObject, SdkPurchaseConfirmationListenerProtocol {
    private let callback: (String) -> Void

    init(callback: @escaping (String) -> Void) {
        self.callback = callback
    }

    func purchaseConfirmationStateChanged(_ state: String?) {
        callback(state ?? "")
    }
}
