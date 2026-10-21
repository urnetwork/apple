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
///
/// The direct-download build adds the method row (Card · USDC · Zcash · Monero, crypto-pay
/// CONTRACT §6.1) directly above the button when the server lists a coin: a coin greys monthly
/// out ("Monthly is card only") and moves the selection to yearly, and the button and its fine
/// print follow the method. The caller's `purchase` reads the method to pay with it.
struct SubscriptionPlanPicker: View {

    @EnvironmentObject var themeManager: ThemeManager

    /// What the cards, the button and the terms line show (see PlanPresentation).
    let presentation: PlanPresentation
    @Binding var selectedPaymentOption: PaymentOption
    /// Buys the selected plan.
    let purchase: () -> Void
    /// A plan card was tapped (the offer surfaces record it).
    var onCardTapped: (PaymentOption) -> Void = { _ in }
    /// The method row (the direct-download build); Card alone shows none.
    var methodRow: PaymentMethodRowState = .card
    /// A pick on the method row.
    var chooseMethod: (PaymentMethod) -> Void = { _ in }

    /// The yearly card's lines: no renewal or trial line while a coin is the
    /// method (crypto-pay CONTRACT §6.1); the coin's fine print says it.
    private var yearlyLines: [String] {
        #if DIRECT_DOWNLOAD
        if methodRow.selected.isCoin {
            return presentation.yearlyLines(oneTime: true)
        }
        #endif
        return presentation.yearlyLines
    }

    /// The height the yearly card reserves: the monthly card's lines, and on
    /// the direct-download build its own card lines too, so the card does not
    /// jump when a coin hides some.
    private var yearlyReservedLineCount: Int {
        #if DIRECT_DOWNLOAD
        return max(presentation.monthlyLines.count, presentation.yearlyLines.count)
        #else
        return presentation.monthlyLines.count
        #endif
    }

    /// The monthly card's lines: "Monthly is card only" while a coin is the method.
    private var monthlyLines: [String] {
        #if DIRECT_DOWNLOAD
        if !methodRow.allowsMonthly {
            return [CryptoPayCopy.monthlyCardOnly]
        }
        #endif
        return presentation.monthlyLines
    }

    /// The button: the plan's call to action for Card, "Pay with {method}" for a coin.
    private var ctaTitle: String {
        #if DIRECT_DOWNLOAD
        if methodRow.selected.isCoin {
            return CryptoPayCopy.payButton(methodRow.selected)
        }
        #endif
        return presentation.ctaTitle(for: selectedPaymentOption)
    }

    /// The line under the button: the plan's terms for Card, a coin's fine print.
    private var termsLine: String? {
        #if DIRECT_DOWNLOAD
        if methodRow.selected.isCoin {
            return CryptoPayCopy.finePrintYearly
        }
        #endif
        return presentation.termsLine(for: selectedPaymentOption)
    }

    var body: some View {
        VStack(alignment: .leading) {

            ProductOptionCard(
                title: presentation.yearlyTitle,
                lines: yearlyLines,
                select: {
                    selectedPaymentOption = .yearly
                    onCardTapped(.yearly)
                },
                isSelected: selectedPaymentOption == .yearly,
                reservedLineCount: yearlyReservedLineCount,
                bestValue: true,
                pill: presentation.yearlyPill,
                deadline: presentation.availableUntilLine()
            )

            Spacer().frame(height: 18)

            ProductOptionCard(
                title: presentation.monthlyTitle,
                lines: monthlyLines,
                select: {
                    selectedPaymentOption = .monthly
                    onCardTapped(.monthly)
                },
                isSelected: selectedPaymentOption == .monthly,
                // equal height with the yearly card, which carries more lines
                reservedLineCount: presentation.yearlyLines.count,
                isEnabled: methodRow.allowsMonthly
            )

            Spacer().frame(height: 18)

            #if DIRECT_DOWNLOAD
            if methodRow.isShown {
                PaymentMethodRowView(row: methodRow, choose: chooseMethod)

                Spacer().frame(height: 12)
            }
            #endif

            UrButton(
                text: LocalizedStringKey(ctaTitle),
                action: purchase
            )

            if let terms = termsLine {
                Spacer().frame(height: 10)

                // the billed amount and the renewal, under the button, every time
                Text(terms)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
        #if DIRECT_DOWNLOAD
        // a coin sells no monthly: the selection moves to yearly
        .onAppear {
            moveOffMonthlyIfNeeded(allowsMonthly: methodRow.allowsMonthly)
        }
        .onChange(of: methodRow.allowsMonthly) { allowsMonthly in
            moveOffMonthlyIfNeeded(allowsMonthly: allowsMonthly)
        }
        #endif
    }

    #if DIRECT_DOWNLOAD
    private func moveOffMonthlyIfNeeded(allowsMonthly: Bool) {
        let plan = PaymentMethodRules.plan(selectedPaymentOption, allowsMonthly: allowsMonthly)
        if plan != selectedPaymentOption {
            selectedPaymentOption = plan
        }
    }
    #endif
}
