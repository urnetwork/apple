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
func yearlySavingPercent(monthly: Product, yearly: Product) -> Int? {
    let twelveMonths = monthly.price * 12
    guard twelveMonths > 0, yearly.price < twelveMonths else {
        return nil
    }
    let saving = (1 - yearly.price / twelveMonths) * 100
    let percent = NSDecimalNumber(decimal: saving).intValue
    return percent > 0 ? percent : nil
}

/// The one plan picker every plan surface shows: onboarding, the upgrade sheet and anything
/// else that sells Pro. Yearly is selected by default in the Pro-gold dress with the "Best
/// value" pill and the free trial; monthly sits below it, quiet, with no trial. The button
/// follows the selection: the trial starts on yearly, monthly just subscribes.
struct SubscriptionPlanPicker: View {

    let monthly: Product
    let yearly: Product
    @Binding var selectedPaymentOption: PaymentOption
    /// Buys the selected plan.
    let purchase: () -> Void

    private var yearlyLabel: String {
        if let percent = yearlySavingPercent(monthly: monthly, yearly: yearly) {
            return "\(yearly.displayPrice) Annual (Save \(percent)%)"
        }
        return "\(yearly.displayPrice) Annual"
    }

    var body: some View {
        VStack(alignment: .leading) {

            ProductOptionCard(
                price: yearlyLabel,
                select: {
                    selectedPaymentOption = .yearly
                },
                isSelected: selectedPaymentOption == .yearly,
                trialDays: yearlyTrialDays(for: yearly),
                bestValue: true
            )

            Spacer().frame(height: 18)

            ProductOptionCard(
                price: "\(monthly.displayPrice)/month",
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
