//
//  ConnectionAwareSubscriptionStore.swift
//  URnetwork
//
//  The store every upgrade surface sells through (makeSubscriptionStore): the
//  build's store, with ConnectViewModel.purchaseAroundConnection around its
//  purchases. It sits here rather than at the surfaces so a new surface cannot
//  buy past it: makeSubscriptionStore takes the connection, and everything
//  else is forwarded as it is.
//

import Foundation
import SwiftUI

@MainActor
final class ConnectionAwareSubscriptionStore: SubscriptionStore {

    private let store: any SubscriptionStore
    private let connection: ConnectViewModel

    init(store: any SubscriptionStore, connection: ConnectViewModel) {
        self.store = store
        self.connection = connection
    }

    func purchase(plan: PaymentOption, onSuccess: @escaping () -> Void) async {
        let store = self.store
        await connection.purchaseAroundConnection {
            await store.purchase(plan: plan, onSuccess: onSuccess)
        }
    }

    func redeemOffer(_ offer: PlanOffer, onSuccess: @escaping () -> Void) async {
        let store = self.store
        await connection.purchaseAroundConnection {
            await store.redeemOffer(offer, onSuccess: onSuccess)
        }
    }

    var storeName: String { store.storeName }
    var distribution: BillingDistribution { store.distribution }

    func presentation(tier: PlanTier?, offer: PlanOffer?, storefrontCountryName: String?) -> PlanPresentation? {
        store.presentation(tier: tier, offer: offer, storefrontCountryName: storefrontCountryName)
    }

    var plansLoadFailed: Bool { store.plansLoadFailed }

    func retryLoadPlansIfNeeded(storefrontCountry: String?) {
        store.retryLoadPlansIfNeeded(storefrontCountry: storefrontCountry)
    }

    var isPurchasing: Bool { store.isPurchasing }
    var purchaseSuccess: Bool { store.purchaseSuccess }
    var purchasePending: Bool { store.purchasePending }
    var purchaseError: String? { store.purchaseError }
    var purchaseConfirmingTitle: String? { store.purchaseConfirmingTitle }
    var purchaseConfirmingMessage: String? { store.purchaseConfirmingMessage }
    var checkoutView: AnyView? { store.checkoutView }

    func resetPurchaseState() {
        store.resetPurchaseState()
    }

    func restorePurchases() async -> RestorePurchasesOutcome {
        await store.restorePurchases()
    }

    var isRestoringPurchases: Bool { store.isRestoringPurchases }
    var restoreResultMessage: String? { store.restoreResultMessage }
}
