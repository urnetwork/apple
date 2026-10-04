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

    // The offer and trial lines put a count in front of a noun. They were
    // formatted from one fixed string, so every language got one noun form
    // ("1 days free", Russian "1 месяца"); the catalog now has plural forms
    // and the count selects one.
    @Test func aCountOfOneReadsInTheSingular() {
        let one = PlanPresentation.resolve(
            tier: .standard,
            offer: PlanOffer(percentOff: 25, monthsFree: 1, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), appleOfferCode: "ABC"),
            storeMonthly: nil,
            storeYearly: nil,
            trialDays: 1,
            equivalent: nil
        )
        #expect(one.ctaTitle(for: .yearly) == "Start free trial with 1 month free")
        #expect(one.termsLine(for: .yearly) == "1 day free, then $29.99 for your first year, then $39.99/year. Cancel anytime.")
        let plain = PlanPresentation.resolve(
            tier: .standard, offer: nil, storeMonthly: nil, storeYearly: nil, trialDays: 1, equivalent: nil
        )
        #expect(plain.termsLine(for: .yearly) == "1 day free, then $39.99/year. Cancel anytime.")
    }

    @Test func theOfferHeadlineSelectsItsPluralForm() {
        #expect(PlanPresentation.monthsFreeHeadline(1) == "1 month of Pro, free")
        #expect(PlanPresentation.monthsFreeHeadline(3) == "3 months of Pro, free")
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

    // MARK: free trial eligibility (support inbox 790, 837, 858)

    private static let twoWeekTrial = PlanIntroOffer(isFreeTrial: true, periodValue: 2, periodUnit: .week)

    @Test func aTrialIsPromisedOnlyForAnEligibleFreeTrialOffer() {
        #expect(planFreeTrialDays(introOffer: Self.twoWeekTrial, isEligible: true) == 14)
        #expect(planFreeTrialDays(introOffer: PlanIntroOffer(isFreeTrial: true, periodValue: 1, periodUnit: .month), isEligible: true) == 30)
        #expect(planFreeTrialDays(introOffer: PlanIntroOffer(isFreeTrial: true, periodValue: 3, periodUnit: .day), isEligible: true) == 3)
    }

    @Test func anIneligibleOrUnknownUserIsPromisedNoTrial() {
        // a user who already had the trial is charged at once
        #expect(planFreeTrialDays(introOffer: Self.twoWeekTrial, isEligible: false) == nil)
        // the store has not answered yet
        #expect(planFreeTrialDays(introOffer: Self.twoWeekTrial, isEligible: nil) == nil)
    }

    @Test func noFreeTrialOfferMeansNoTrialEvenWhenEligible() {
        // no introductory offer: no fallback length is invented
        #expect(planFreeTrialDays(introOffer: nil, isEligible: true) == nil)
        // a paid introductory offer is not a free trial
        #expect(planFreeTrialDays(introOffer: PlanIntroOffer(isFreeTrial: false, periodValue: 1, periodUnit: .month), isEligible: true) == nil)
        #expect(planFreeTrialDays(introOffer: PlanIntroOffer(isFreeTrial: true, periodValue: 0, periodUnit: .day), isEligible: true) == nil)
    }

    @Test func withoutATrialThePaywallStatesThePlainTerms() {
        let presentation = PlanPresentation.resolve(
            tier: .standard,
            offer: nil,
            storeMonthly: nil,
            storeYearly: nil,
            trialDays: planFreeTrialDays(introOffer: Self.twoWeekTrial, isEligible: false),
            equivalent: PlanEquivalent(monthlyEquivalent: Decimal(string: "3.34")!, showEquivalent: true, savingPercent: 33)
        )
        #expect(presentation.yearlyLines == ["≈ $3.34/month · billed once a year"])
        #expect(!presentation.yearlyLines.contains { $0.localizedCaseInsensitiveContains("trial") })
        #expect(presentation.ctaTitle(for: .yearly) == "Subscribe")
        #expect(presentation.termsLine(for: .yearly) == "$39.99 billed today, then every year. Cancel anytime.")
    }

    @Test func withTheWelcomeOfferButNoTrialTheTermsDropTheFreeDays() {
        let presentation = PlanPresentation.resolve(
            tier: .standard,
            offer: PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date(), appleOfferCode: "ABC"),
            storeMonthly: nil,
            storeYearly: nil,
            trialDays: nil,
            equivalent: nil
        )
        #expect(presentation.yearlyLines == ["then $39.99/year"])
        #expect(presentation.termsLine(for: .yearly) == "$29.99 for your first year, then $39.99/year. Cancel anytime.")
    }
}
