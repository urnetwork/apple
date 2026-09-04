//
//  SubscriptionPlanPicker.swift
//  URnetwork
//

import SwiftUI
import StoreKit

/// The App Store cannot run a 15 day trial: two weeks is the closest offer, and the real
/// length comes from StoreKit when the offer is configured.
let subscriptionFallbackTrialDays = 14

/// The annual plan's free trial in days, from its introductory offer when the store has one.
func yearlyTrialDays(for yearly: Product?) -> Int {
    guard let offer = yearly?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else {
        return subscriptionFallbackTrialDays
    }
    let period = offer.period
    switch period.unit {
    case .day:
        return period.value
    case .week:
        return period.value * 7
    case .month:
        return period.value * 30
    case .year:
        return period.value * 365
    @unknown default:
        return subscriptionFallbackTrialDays
    }
}

/// The yearly plan's saving against twelve months of the monthly plan, as a whole percent
/// ("Save 33%"); nil when the prices do not make a saving.
func yearlySavingPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
    // display-only math, done in Double: NSDecimalNumber.intValue answers 0 for the
    // 38-digit quotient a Decimal division produces, which hid the saving entirely
    let twelveMonths = NSDecimalNumber(decimal: monthlyPrice * 12).doubleValue
    let yearly = NSDecimalNumber(decimal: yearlyPrice).doubleValue
    guard twelveMonths > 0, yearly < twelveMonths else {
        return nil
    }
    let percent = Int(((1 - yearly / twelveMonths) * 100).rounded(.down))
    return percent > 0 ? percent : nil
}

/// What the picker shows for each plan. The plans always exist on the App Store, so the picker
/// never waits for StoreKit: until the products arrive (and when they never do) it shows the
/// store's list prices, and a loaded product only refines its own row.
struct SubscriptionPlanPrices: Equatable {
    var monthlyDisplayPrice: String
    var yearlyDisplayPrice: String
    var monthlyPrice: Decimal
    var yearlyPrice: Decimal
    var trialDays: Int

    /// The App Store list prices, shown until StoreKit answers.
    static let fallback = SubscriptionPlanPrices(
        monthlyDisplayPrice: "$4.99",
        yearlyDisplayPrice: "$39.99",
        monthlyPrice: Decimal(string: "4.99")!,
        yearlyPrice: Decimal(string: "39.99")!,
        trialDays: subscriptionFallbackTrialDays
    )

    /// The fallback, with each row refined by its product once the store has it.
    static func resolve(monthly: Product?, yearly: Product?) -> SubscriptionPlanPrices {
        var prices = fallback
        if let monthly {
            prices.monthlyDisplayPrice = monthly.displayPrice
            prices.monthlyPrice = monthly.price
        }
        if let yearly {
            prices.yearlyDisplayPrice = yearly.displayPrice
            prices.yearlyPrice = yearly.price
        }
        prices.trialDays = yearlyTrialDays(for: yearly)
        return prices
    }

    var savingPercent: Int? {
        yearlySavingPercent(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice)
    }

    /// "$39.99 Annual (Save 33%)"
    var yearlyLabel: String {
        if let percent = savingPercent {
            return "\(yearlyDisplayPrice) Annual (Save \(percent)%)"
        }
        return "\(yearlyDisplayPrice) Annual"
    }

    /// "$4.99/month"
    var monthlyLabel: String {
        "\(monthlyDisplayPrice)/month"
    }
}

/// The one plan picker every plan surface shows: onboarding, the upgrade sheet and anything
/// else that sells Pro. Yearly is selected by default in the Pro-gold dress with the "Best
/// value" pill and the free trial; monthly sits below it, quiet, with no trial. The button
/// follows the selection: the trial starts on yearly, monthly just subscribes. The layout is
/// the same before, during and after the store answers (see SubscriptionPlanPrices); a tap on
/// a plan whose product is missing is the caller's to report.
struct SubscriptionPlanPicker: View {

    let monthly: Product?
    let yearly: Product?
    @Binding var selectedPaymentOption: PaymentOption
    /// Buys the selected plan.
    let purchase: () -> Void

    private var prices: SubscriptionPlanPrices {
        .resolve(monthly: monthly, yearly: yearly)
    }

    var body: some View {
        VStack(alignment: .leading) {

            ProductOptionCard(
                price: prices.yearlyLabel,
                select: {
                    selectedPaymentOption = .yearly
                },
                isSelected: selectedPaymentOption == .yearly,
                trialDays: prices.trialDays,
                bestValue: true
            )

            Spacer().frame(height: 18)

            ProductOptionCard(
                price: prices.monthlyLabel,
                select: {
                    selectedPaymentOption = .monthly
                },
                isSelected: selectedPaymentOption == .monthly
            )

            Spacer().frame(height: 18)

            UrButton(
                text: selectedPaymentOption == .monthly
                    ? "Subscribe"
                    : "Start free trial",
                action: purchase
            )
        }
    }
}
