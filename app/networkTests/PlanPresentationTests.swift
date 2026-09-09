import Foundation
import Testing
@testable import URnetwork

struct PlanPresentationTests {

    private static let usd: (Decimal) -> String = PlanPrice.formatUsd

    private static func standard(offer: PlanOffer? = nil) -> PlanPresentation {
        PlanPresentation.resolve(
            tier: .standard,
            offer: offer,
            storeMonthly: nil,
            storeYearly: nil,
            trialDays: 14,
            equivalent: PlanEquivalent(monthlyEquivalent: Decimal(string: "3.34")!, showEquivalent: true, savingPercent: 33)
        )
    }

    @Test func listPricesLandOnTheStorePoint() {
        #expect(PlanPrice.storePoint(40) == Decimal(string: "39.99")!)
        #expect(PlanPrice.storePoint(5) == Decimal(string: "4.99")!)
        #expect(PlanPrice.storePoint(0.5) == Decimal(string: "0.49")!)
        #expect(PlanPrice.storePoint(4) == Decimal(string: "3.99")!)
        #expect(PlanPrice.storePoint(29.99) == Decimal(string: "29.99")!)
    }

    @Test func theYearlyPlanLeadsWithTheBilledAmountAndCarriesTheEquivalent() {
        let presentation = Self.standard()
        #expect(presentation.yearlyTitle == "$39.99/year")
        #expect(presentation.yearlyLines == ["≈ $3.34/month · billed once a year", "Includes 14 day free trial"])
        #expect(presentation.yearlyPill == "Save 33%")
        #expect(presentation.monthlyTitle == "$4.99/month")
        #expect(presentation.monthlyLines == ["Billed monthly · cancel anytime"])
        #expect(presentation.ctaTitle(for: .yearly) == "Start free trial")
        #expect(presentation.ctaTitle(for: .monthly) == "Subscribe")
        #expect(presentation.termsLine(for: .yearly) == "14 days free, then $39.99/year. Cancel anytime.")
        #expect(presentation.termsLine(for: .monthly) == nil)
        #expect(presentation.availableUntilLine() == nil)
    }

    @Test func theRegionalTierNeverShowsAPerMonthEquivalent() {
        let presentation = PlanPresentation.resolve(
            tier: PlanTier(name: "regional", yearlyUsd: 4, monthlyUsd: 0.5, isRegional: true),
            offer: nil,
            storeMonthly: nil,
            storeYearly: nil,
            trialDays: 14,
            equivalent: PlanEquivalent(monthlyEquivalent: Decimal(string: "0.34")!, showEquivalent: false, savingPercent: 33),
            storefrontCountryName: "Nigeria"
        )
        #expect(presentation.yearlyTitle == "$3.99/year")
        #expect(presentation.yearlyLines == ["Billed once a year · price for Nigeria", "Includes 14 day free trial"])
        #expect(presentation.monthlyTitle == "$0.49/month")
    }

    @Test func theWelcomeOfferReplacesTheHeadlineWithTheFirstYear() {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let presentation = Self.standard(offer: PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: expires, appleOfferCode: "ABC"))
        #expect(presentation.firstYearPrice?.display == "$29.99")
        #expect(presentation.yearlyTitle == "$29.99 for your first year")
        #expect(presentation.yearlyLines == ["then $39.99/year", "Includes 14 day free trial"])
        #expect(presentation.ctaTitle(for: .yearly) == "Start free trial with 3 months free")
        #expect(presentation.termsLine(for: .yearly) == "14 days free, then $29.99 for your first year, then $39.99/year. Cancel anytime.")
        #expect(presentation.availableUntilLine()?.hasPrefix("Available until ") == true)
    }

    @Test func aLoadedProductRefinesItsOwnRowInItsOwnCurrency() {
        let euro: (Decimal) -> String = { "€\($0)" }
        let presentation = PlanPresentation.resolve(
            tier: .standard,
            offer: PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date(), appleOfferCode: ""),
            storeMonthly: nil,
            storeYearly: PlanPrice(amount: Decimal(string: "40.99")!, currencyCode: "EUR", format: euro),
            trialDays: 14,
            equivalent: nil
        )
        // 40.99 × 0.75 = 30.7425, rounded down to the cent
        #expect(presentation.firstYearPrice?.display == "€30.74")
        #expect(presentation.yearlyTitle == "€30.74 for your first year")
        #expect(presentation.monthlyTitle == "$4.99/month")
        #expect(presentation.yearlyPill == "Best value")
    }
}
