//
//  SubscriptionPlanPicker.swift
//  URnetwork
//

import SwiftUI
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif

#if !DIRECT_DOWNLOAD

extension PlanIntroOffer {
    /// The introductory offer as the trial decision needs it; nil for a period unit StoreKit adds later.
    init?(offer: Product.SubscriptionOffer) {
        let unit: Unit
        switch offer.period.unit {
        case .day:
            unit = .day
        case .week:
            unit = .week
        case .month:
            unit = .month
        case .year:
            unit = .year
        @unknown default:
            return nil
        }
        self.init(isFreeTrial: offer.paymentMode == .freeTrial, periodValue: offer.period.value, periodUnit: unit)
    }
}

/**
 * The annual plan's free trial in days, or nil when none may be promised: the
 * product must have a free-trial introductory offer and StoreKit must report
 * this user eligible for it (a user who already had a trial in the group is
 * charged at once). The length is the offer's real period, never a guess.
 */
func storeYearlyTrialDays(for yearly: Product?) async -> Int? {
    guard let subscription = yearly?.subscription, let offer = subscription.introductoryOffer else {
        return nil
    }
    let isEligible = await subscription.isEligibleForIntroOffer
    return planFreeTrialDays(introOffer: PlanIntroOffer(offer: offer), isEligible: isEligible)
}

#endif

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
