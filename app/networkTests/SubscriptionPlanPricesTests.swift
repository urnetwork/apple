import Foundation
import Testing
@testable import URnetwork

struct SubscriptionPlanPricesTests {

    @Test func thePickerHasPricesBeforeTheStoreAnswers() {
        let prices = SubscriptionPlanPrices.resolve(monthly: nil, yearly: nil)
        #expect(prices == .fallback)
        #expect(prices.yearlyLabel == "$39.99 Annual (Save 33%)")
        #expect(prices.monthlyLabel == "$4.99/month")
        #expect(prices.trialDays == subscriptionFallbackTrialDays)
    }

    @Test func theSavingIsAWholePercentOfTwelveMonths() {
        #expect(yearlySavingPercent(
            monthlyPrice: Decimal(string: "4.99")!,
            yearlyPrice: Decimal(string: "39.99")!
        ) == 33)
        // twelve months at the monthly price, or more, is no saving
        #expect(yearlySavingPercent(monthlyPrice: 5, yearlyPrice: 60) == nil)
        #expect(yearlySavingPercent(monthlyPrice: 5, yearlyPrice: 70) == nil)
        #expect(yearlySavingPercent(monthlyPrice: 0, yearlyPrice: 10) == nil)
    }

    @Test func theYearlyLabelDropsTheSavingWhenThereIsNone() {
        var prices = SubscriptionPlanPrices.fallback
        prices.yearlyDisplayPrice = "$59.88"
        prices.yearlyPrice = Decimal(string: "59.88")!
        #expect(prices.savingPercent == nil)
        #expect(prices.yearlyLabel == "$59.88 Annual")
    }
}
