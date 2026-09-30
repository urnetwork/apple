import Foundation
import Testing
@testable import URnetwork
import URnetworkSdk

/// The plan cards built from the server's Stripe prices (direct-download macOS build).
struct PlanPresentationStripeTests {

    private static let offer = PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), appleOfferCode: "")

    @Test func stripeChargesTheExactAmountNotTheStorePoint() {
        let prices = StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: false)
        let presentation = PlanPresentation.stripe(prices: prices, tier: .standard, offer: nil)
        #expect(presentation.yearly.amount == 40)
        #expect(presentation.yearly.currencyCode == "USD")
        #expect(presentation.yearlyTitle == "$40.00/year")
        #expect(presentation.monthlyTitle == "$5.00/month")
        // the SDK's per-month equivalent and saving, as on every platform
        #expect(presentation.yearlyLines.first == "≈ $3.34/month · billed once a year")
        #expect(presentation.yearlyPill == "Save 33%")
    }

    @Test func noFreeTrialIsPromisedFromThePrices() {
        let prices = StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: false)
        let presentation = PlanPresentation.stripe(prices: prices, tier: .standard, offer: nil)
        #expect(presentation.trialDays == nil)
        #expect(presentation.ctaTitle(for: .yearly) == "Subscribe")
        #expect(presentation.termsLine(for: .yearly) == "$40.00 billed today, then every year. Cancel anytime.")
        #expect(!presentation.yearlyLines.contains { $0.contains("free trial") })
    }

    @Test func theOfferShowsOnlyWhenThePricesSayItIsRedeemable() {
        let eligible = StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: true)
        let shown = PlanPresentation.stripe(prices: eligible, tier: .standard, offer: Self.offer)
        #expect(shown.hasOffer)
        #expect(shown.yearlyTitle == "$30.00 for your first year")

        let ineligible = StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: false)
        let hidden = PlanPresentation.stripe(prices: ineligible, tier: .standard, offer: Self.offer)
        #expect(!hidden.hasOffer)
        #expect(hidden.yearlyTitle == "$40.00/year")
    }

    @Test func theRegionalTierKeepsItsBillingLine() {
        let prices = StripePlanPrices(yearlyUsd: 20, monthlyUsd: 2.5, currency: "usd", offerEligible: false)
        let tier = PlanTier(name: "regional", yearlyUsd: 20, monthlyUsd: 2.5, isRegional: true)
        let presentation = PlanPresentation.stripe(prices: prices, tier: tier, offer: nil, storefrontCountryName: "Brazil")
        #expect(presentation.yearlyTitle == "$20.00/year")
        #expect(presentation.monthlyTitle == "$2.50/month")
        #expect(presentation.yearlyLines.first == "Billed once a year · price for Brazil")
    }

    @Test func anEmptyCurrencyReadsAsUSD() {
        let price = PlanPrice.stripePrice(12.5, currency: "")
        #expect(price.currencyCode == "USD")
        #expect(price.display == "$12.50")
    }

    @Test func theSDKResultBuildsTheSamePresentation() {
        let result = SdkStripePricesResult()
        result.yearlyUsd = 40
        result.monthlyUsd = 5
        result.currency = "usd"
        result.offerEligible = true
        result.publishableKey = "pk_test"
        let fromResult = PlanPresentation(stripePrices: result, tier: .standard, offer: Self.offer)
        let fromValues = PlanPresentation.stripe(
            prices: StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: true, publishableKey: "pk_test"),
            tier: .standard,
            offer: Self.offer
        )
        #expect(fromResult == fromValues)
        #expect(StripePlanPrices(result).publishableKey == "pk_test")
    }
}
