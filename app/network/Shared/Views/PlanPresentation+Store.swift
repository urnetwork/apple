//
//  PlanPresentation+Store.swift
//  URnetwork
//
//  The presentation built from what the session has: the StoreKit products
//  when they loaded, the balance's tier and offer, and the SDK's per-month
//  equivalent (so every platform shows the same figures).
//

import Foundation
import StoreKit
import URnetworkSdk

extension PlanPrice {
    init(product: Product) {
        let style = product.priceFormatStyle
        self.init(amount: product.price, currencyCode: style.currencyCode, format: { amount in amount.formatted(style) })
    }
}

extension PlanPresentation {

    /// The presentation every plan surface shows for this session.
    static func current(
        monthly: Product?,
        yearly: Product?,
        tier: PlanTier?,
        offer: PlanOffer?,
        storefrontCountryName: String?
    ) -> PlanPresentation {
        let yearlyPrice = yearly.map(PlanPrice.init(product:)) ?? .usdListPrice((tier ?? .standard).yearlyUsd)
        let monthlyPrice = monthly.map(PlanPrice.init(product:)) ?? .usdListPrice((tier ?? .standard).monthlyUsd)
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
            trialDays: yearlyTrialDays(for: yearly),
            equivalent: equivalent,
            storefrontCountryName: storefrontCountryName
        )
    }
}
