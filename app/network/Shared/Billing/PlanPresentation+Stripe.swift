//
//  PlanPresentation+Stripe.swift
//  URnetwork
//
//  The plan presentation the direct-download build renders from the server's
//  Stripe prices (GET /subscription/stripe/prices). Stripe charges the tier's
//  exact amount (no $39.99 store point), the welcome offer applies only when
//  the prices say the caller is eligible for its coupon, and no free trial is
//  promised: the prices carry none (the pay sheet answers with the trial once
//  the purchase starts, too late for the plan card to promise it).
//

import Foundation
import URnetworkSdk

/// The Stripe prices as the presentation needs them (SDK-free, so it can be built in tests).
struct StripePlanPrices: Equatable {
    var yearlyUsd: Double
    var monthlyUsd: Double
    /// The ISO 4217 code the amounts are in ("usd").
    var currency: String
    /// The caller may redeem the welcome offer's coupon (yearly only).
    var offerEligible: Bool
    var publishableKey: String = ""

    init(yearlyUsd: Double, monthlyUsd: Double, currency: String, offerEligible: Bool, publishableKey: String = "") {
        self.yearlyUsd = yearlyUsd
        self.monthlyUsd = monthlyUsd
        self.currency = currency
        self.offerEligible = offerEligible
        self.publishableKey = publishableKey
    }

    init(_ result: SdkStripePricesResult) {
        self.init(
            yearlyUsd: result.yearlyUsd,
            monthlyUsd: result.monthlyUsd,
            currency: result.currency,
            offerEligible: result.offerEligible,
            publishableKey: result.publishableKey
        )
    }
}

extension PlanPrice {

    /// A Stripe price: the exact amount, in its currency ("$40.00" for usd,
    /// the locale's currency format otherwise).
    static func stripePrice(_ amount: Double, currency: String) -> PlanPrice {
        let code = currency.isEmpty ? "USD" : currency.uppercased()
        let decimal = Decimal(Int((amount * 100).rounded())) / 100
        if code == "USD" {
            return PlanPrice(amount: decimal, currencyCode: code, format: Self.formatUsd)
        }
        return PlanPrice(amount: decimal, currencyCode: code, format: { amount in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount) \(code)"
        })
    }
}

extension PlanPresentation {

    /// The presentation from the server's Stripe prices. `offer` is the balance's
    /// welcome offer; it is shown only while the prices say it is redeemable.
    static func stripe(
        prices: StripePlanPrices,
        tier: PlanTier?,
        offer: PlanOffer?,
        storefrontCountryName: String? = nil
    ) -> PlanPresentation {
        let yearly = PlanPrice.stripePrice(prices.yearlyUsd, currency: prices.currency)
        let monthly = PlanPrice.stripePrice(prices.monthlyUsd, currency: prices.currency)
        var equivalent: PlanEquivalent? = nil
        if let computed = SdkComputePriceEquivalent(prices.yearlyUsd, prices.monthlyUsd, 2) {
            equivalent = PlanEquivalent(
                monthlyEquivalent: Decimal(computed.monthlyEquivalentMinor) / 100,
                showEquivalent: computed.showEquivalent,
                savingPercent: computed.savingPercent
            )
        }
        return resolve(
            tier: tier,
            offer: prices.offerEligible ? offer : nil,
            storeMonthly: monthly,
            storeYearly: yearly,
            // no trial promise: the prices do not say the user gets one
            trialDays: nil,
            equivalent: equivalent,
            storefrontCountryName: storefrontCountryName
        )
    }

    init(
        stripePrices: SdkStripePricesResult,
        tier: PlanTier?,
        offer: PlanOffer?,
        storefrontCountryName: String? = nil
    ) {
        self = .stripe(
            prices: StripePlanPrices(stripePrices),
            tier: tier,
            offer: offer,
            storefrontCountryName: storefrontCountryName
        )
    }
}
