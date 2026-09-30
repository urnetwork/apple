//
//  StoreKitSubscriptionStore.swift
//  URnetwork
//
//  The App Store's SubscriptionStore: a thin forwarder over the existing
//  AppStoreSubscriptionManager, so the App Store purchase path is exactly
//  what it was. The plan-to-product step used to live in the upgrade sheet
//  (a tap on a plan whose product has not loaded reports it and asks the
//  store again); it lives here now.
//

import Foundation
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif
import SwiftUI
import URnetworkSdk

@MainActor
final class StoreKitSubscriptionStore: SubscriptionStore {

    let manager: AppStoreSubscriptionManager

    init(manager: AppStoreSubscriptionManager) {
        self.manager = manager
    }

    var storeName: String { SdkEventStoreApple }
    let distribution: BillingDistribution = .appStore

    // the sheet builds the presentation from the products, as it always has
    func presentation(tier: PlanTier?, offer: PlanOffer?, storefrontCountryName: String?) -> PlanPresentation? {
        nil
    }

    var plansLoadFailed: Bool { manager.fetchProductsError }

    func retryLoadPlansIfNeeded(storefrontCountry: String?) {
        manager.retryFetchProductsIfNeeded()
    }

    func product(for plan: PaymentOption) -> Product? {
        plan == .monthly ? manager.monthlySubscription : manager.yearlySubscription
    }

    func purchase(plan: PaymentOption, onSuccess: @escaping () -> Void) async {
        guard let product = product(for: plan) else {
            manager.reportProductsUnavailable()
            return
        }
        do {
            try await manager.purchase(product: product, onSuccess: onSuccess)
        } catch {
            // rendered inline via purchaseError
            print("error making purchase: \(error)")
        }
    }

    var isPurchasing: Bool { manager.isPurchasing }
    var purchaseSuccess: Bool { manager.purchaseSuccess }
    var purchasePending: Bool { manager.purchasePending }
    var purchaseError: String? { manager.purchaseError }
    var purchaseConfirmingTitle: String? { nil }
    var purchaseConfirmingMessage: String? { nil }
    var checkoutView: AnyView? { nil }

    func resetPurchaseState() {
        manager.resetPurchaseState()
    }

    func restorePurchases() async -> RestorePurchasesOutcome {
        await manager.restorePurchases()
    }

    var isRestoringPurchases: Bool { manager.isRestoringPurchases }
    var restoreResultMessage: String? { manager.restoreResultMessage }
}
