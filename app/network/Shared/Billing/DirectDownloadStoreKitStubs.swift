//
//  DirectDownloadStoreKitStubs.swift
//  URnetwork
//
//  Direct-download macOS build only (`DIRECT_DOWNLOAD`). That build bills
//  through Stripe (StripeSubscriptionStore) and must not link StoreKit, so
//  every `import StoreKit` is compiled out of it. The plan surfaces the two
//  builds share are typed on StoreKit's `Product` and observe the
//  `AppStoreSubscriptionManager`; these inert stand-ins keep that code
//  compiling with nothing to sell: no products ever load, so nothing reaches
//  a purchase (every surface sells through the build's SubscriptionStore,
//  Stripe here), and "restore" re-checks the plan with the server.
//

#if DIRECT_DOWNLOAD

import Combine
import Foundation
import URnetworkSdk

/// Stands in for StoreKit's Product. No value of it is ever created.
struct Product: Identifiable, Equatable {
    let id: String
}

/// The App Store manager's observable surface, inert (see the file header).
@MainActor
class AppStoreSubscriptionManager: ObservableObject {

    @Published var monthlySubscription: Product?
    @Published var yearlySubscription: Product?
    @Published private(set) var yearlyTrialDays: Int?
    @Published private(set) var hasAppStoreSubscription: Bool = false
    @Published var isPurchasing: Bool = false
    @Published private(set) var purchaseSuccess: Bool = false
    @Published private(set) var purchasePending: Bool = false
    @Published private(set) var purchaseError: String?
    @Published private(set) var fetchProductsError: Bool = false
    @Published private(set) var isRestoringPurchases: Bool = false
    @Published private(set) var restoreResultMessage: String?
    @Published private(set) var transactionUpdateSequence: Int = 0

    var onPurchaseSuccess: (() -> Void)?

    init(networkId: SdkId?) {}

    static func plan(forProductId id: String) -> String {
        id == "supporter_monthly_26" ? SdkPlanMonthly : SdkPlanYearly
    }

    func refreshHasAppStoreSubscription() async {}

    func fetchProducts() async {}

    func refreshYearlyTrialDays() async {}

    func retryFetchProductsIfNeeded() {}

    func redeemOffer(code: String, yearly: Product?, onSuccess: @escaping (() -> Void)) async {
        reportProductsUnavailable()
    }

    func purchase(product: Product, onSuccess: @escaping (() -> Void)) async throws {
        reportProductsUnavailable()
    }

    /// Nothing to restore from the App Store here; the server is the record
    /// and the caller re-runs the confirmation poll on `.restored`.
    func restorePurchases() async -> RestorePurchasesOutcome {
        restoreResultMessage = String(localized: "Checking your plan again.")
        return .restored
    }

    func setPurchaseSuccess(_ success: Bool) {
        purchaseSuccess = success
    }

    func setPurchasePending(_ pending: Bool) {
        purchasePending = pending
    }

    func resetPurchaseState() {
        if purchaseSuccess { purchaseSuccess = false }
        if purchasePending { purchasePending = false }
        if purchaseError != nil { purchaseError = nil }
        if restoreResultMessage != nil { restoreResultMessage = nil }
    }

    /// No surface sells through these products on this build (see the file
    /// header); a tap that still lands here reads as the App Store's
    /// products-not-loaded failure.
    func reportProductsUnavailable() {
        let message = String(localized: "Couldn't load subscription options. Check your connection and retry.")
        if purchaseError != message { purchaseError = message }
    }
}

#endif
