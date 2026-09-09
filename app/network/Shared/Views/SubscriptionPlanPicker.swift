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

/// The one plan picker every plan surface shows: onboarding, the upgrade sheet and anything
/// else that sells Pro. Yearly is selected by default in the Pro-gold dress with the pill and
/// the free trial; monthly sits below it, quiet, with no trial. The button and the terms line
/// follow the selection: the trial starts on yearly, monthly just subscribes. The layout is
/// the same before, during and after the store answers (see PlanPresentation); a tap on a plan
/// whose product is missing is the caller's to report.
struct SubscriptionPlanPicker: View {

    @EnvironmentObject var themeManager: ThemeManager

    /// What the cards, the button and the terms line show (see PlanPresentation).
    let presentation: PlanPresentation
    @Binding var selectedPaymentOption: PaymentOption
    /// Buys the selected plan.
    let purchase: () -> Void
    /// A plan card was tapped (the offer surfaces record it).
    var onCardTapped: (PaymentOption) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading) {

            ProductOptionCard(
                title: presentation.yearlyTitle,
                lines: presentation.yearlyLines,
                select: {
                    selectedPaymentOption = .yearly
                    onCardTapped(.yearly)
                },
                isSelected: selectedPaymentOption == .yearly,
                reservedLineCount: presentation.monthlyLines.count,
                bestValue: true,
                pill: presentation.yearlyPill,
                deadline: presentation.availableUntilLine()
            )

            Spacer().frame(height: 18)

            ProductOptionCard(
                title: presentation.monthlyTitle,
                lines: presentation.monthlyLines,
                select: {
                    selectedPaymentOption = .monthly
                    onCardTapped(.monthly)
                },
                isSelected: selectedPaymentOption == .monthly,
                // equal height with the yearly card, which carries more lines
                reservedLineCount: presentation.yearlyLines.count
            )

            Spacer().frame(height: 18)

            UrButton(
                text: LocalizedStringKey(presentation.ctaTitle(for: selectedPaymentOption)),
                action: purchase
            )

            if let terms = presentation.termsLine(for: selectedPaymentOption) {
                Spacer().frame(height: 10)

                // the billed amount and the renewal, under the button, every time
                Text(terms)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
    }
}
