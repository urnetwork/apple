//
//  PlanPresentation+Store.swift
//  URnetwork
//
//  The presentation built from what the session has: the StoreKit products
//  when they loaded, the balance's tier and offer, and the SDK's per-month
//  equivalent (so every platform shows the same figures).
//

import Foundation
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif
import URnetworkSdk

#if !DIRECT_DOWNLOAD
extension PlanPrice {
    init(product: Product) {
        let style = product.priceFormatStyle
        self.init(amount: product.price, currencyCode: style.currencyCode, format: { amount in amount.formatted(style) })
    }
}
#endif

extension PlanPresentation {

    /// The presentation every plan surface shows for this session. `yearlyTrialDays` is the
    /// trial StoreKit says this user may get (AppStoreSubscriptionManager.yearlyTrialDays).
    static func current(
        monthly: Product?,
        yearly: Product?,
        tier: PlanTier?,
        offer: PlanOffer?,
        storefrontCountryName: String?,
        yearlyTrialDays: Int?
    ) -> PlanPresentation {
        #if DIRECT_DOWNLOAD
        // no StoreKit products on the direct-download build (Stripe prices go
        // through PlanPresentation+Stripe); the tier's list prices stand in
        let yearlyPrice = PlanPrice.usdListPrice((tier ?? .standard).yearlyUsd)
        let monthlyPrice = PlanPrice.usdListPrice((tier ?? .standard).monthlyUsd)
        #else
        let yearlyPrice = yearly.map(PlanPrice.init(product:)) ?? .usdListPrice((tier ?? .standard).yearlyUsd)
        let monthlyPrice = monthly.map(PlanPrice.init(product:)) ?? .usdListPrice((tier ?? .standard).monthlyUsd)
        #endif
        var equivalent: PlanEquivalent? = nil
        if let computed = SdkComputePriceEquivalent(
            NSDecimalNumber(decimal: yearlyPrice.amount).doubleValue,
            NSDecimalNumber(decimal: monthlyPrice.amount).doubleValue,
            2
        ) {
            equivalent = PlanEquivalent(
                monthlyEquivalent: Decimal(computed.monthlyEquivalentMinor) / 100,
                showEquivalent: computed.showEquivalent,
                savingPercent: computed.savingPercent
            )
        }
        return resolve(
            tier: tier,
            offer: offer,
            storeMonthly: monthlyPrice,
            storeYearly: yearlyPrice,
            trialDays: yearlyTrialDays,
            equivalent: equivalent,
            storefrontCountryName: storefrontCountryName
        )
    }
}
