//
//  SubscriptionStore.swift
//  URnetwork
//
//  What an upgrade surface needs from whoever sells Pro: the plans (as the
//  presentation shows them), a purchase of a plan, the manage/cancel hand-off
//  and the per-attempt state the sheet renders. The App Store build goes
//  through StoreKitSubscriptionStore (AppStoreSubscriptionManager, unchanged);
//  the direct-download build through StripeSubscriptionStore.
//

import Foundation
import SwiftUI

@MainActor
protocol SubscriptionStore: AnyObject {

    /// The store the purchase events carry (SdkEventStoreApple / SdkEventStoreStripe).
    var storeName: String { get }
    var distribution: BillingDistribution { get }

    // MARK: plans

    /// The presentation of the plans this store sells, or nil when the sheet
    /// should build it from the StoreKit products as it always has.
    func presentation(tier: PlanTier?, offer: PlanOffer?, storefrontCountryName: String?) -> PlanPresentation?
    /// The plans could not be loaded (nothing to sell; the sheet offers a retry).
    var plansLoadFailed: Bool { get }
    func retryLoadPlansIfNeeded(storefrontCountry: String?)

    // MARK: purchase

    /// Buys the plan. `onSuccess` runs when the store took the payment: the
    /// caller starts the confirmation poll (the server only believes the
    /// store's webhook). Errors surface through `purchaseError`.
    func purchase(plan: PaymentOption, onSuccess: @escaping () -> Void) async
    var isPurchasing: Bool { get }
    var purchaseSuccess: Bool { get }
    var purchasePending: Bool { get }
    var purchaseError: String? { get }
    /// The success screen's title and copy while the server confirms; nil for
    /// the StoreKit defaults.
    var purchaseConfirmingTitle: String? { get }
    var purchaseConfirmingMessage: String? { get }
    /// The in-app checkout page while one is open (the sheet shows it over the plans).
    var checkoutView: AnyView? { get }
    func resetPurchaseState()

    // MARK: restore

    func restorePurchases() async -> RestorePurchasesOutcome
    var isRestoringPurchases: Bool { get }
    var restoreResultMessage: String? { get }
}

/// The store a surface sells through, by distribution.
@MainActor
func makeSubscriptionStore(
    for distribution: BillingDistribution,
    appStore: AppStoreSubscriptionManager,
    stripe: StripeSubscriptionStore
) -> any SubscriptionStore {
    switch distribution {
    case .appStore:
        return StoreKitSubscriptionStore(manager: appStore)
    case .direct:
        return stripe
    }
}
