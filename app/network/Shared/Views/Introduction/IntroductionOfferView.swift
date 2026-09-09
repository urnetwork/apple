//
//  IntroductionOfferView.swift
//  URnetwork
//
//  The last onboarding page, reached by everyone who is not in the holdout,
//  Skip included: the welcome offer, once, as an honest soft paywall. The
//  headline leads with the months free, the card leads with the amount
//  billed, the deadline is a static date, the trial timeline says when the
//  charge happens, one primary button starts the trial, and the free plan is
//  one tap away underneath. No countdown, no second offer on decline.
//
//  Also presented on its own from an email's offer link (`standalone`), with
//  a close control instead of the onboarding chrome.
//

import SwiftUI
import URnetworkSdk

struct IntroductionOfferView: View {

    @EnvironmentObject var themeManager: ThemeManager

    /// The offer with the prices; the view is not shown without one.
    let presentation: PlanPresentation
    /// Keeps the free plan and finishes the flow (the link, and Skip).
    let continueFree: () -> Void
    /// Goes back a page; nil when the view stands alone.
    var back: (() -> Void)? = nil
    /// Starts the trial with the offer.
    let startTrial: () -> Void
    var isPurchasing: Bool = false
    var purchaseError: String? = nil
    /// Presented from an email link rather than as an onboarding page.
    var standalone: Bool = false
    /// The surface named on the events.
    var surface: String = SdkOfferSurfaceFinalScreen
    var experimentId: String = ""
    var experimentVariant: String = ""

    @State private var shownAt: Date? = nil

    private var elapsedMillis: Int64 {
        guard let shownAt else { return 0 }
        return max(0, Int64(Date().timeIntervalSince(shownAt) * 1000))
    }

    private func decline(_ control: String, then action: () -> Void) {
        ClientEvents.shared.offerDeclined(control: control, elapsedMillis: elapsedMillis)
        action()
    }

    private var timeline: [(label: String, text: String)] {
        let days = presentation.trialDays
        let firstYear = presentation.firstYearPrice?.display ?? presentation.yearly.display
        return [
            (String(localized: "Today"), String(localized: "Free trial starts")),
            (String(format: String(localized: "Day %lld"), max(days - 2, 1)), String(localized: "Reminder before the charge")),
            (String(format: String(localized: "Day %lld"), days), String(format: String(localized: "%@ for the year, cancel anytime before"), firstYear)),
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    if standalone {
                        HStack {
                            Spacer()
                            Button(action: { decline(SdkOfferDeclineControlBack, then: continueFree) }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close")
                        }
                    } else {
                        IntroductionTopBar(
                            step: IntroStep.offer.rawValue + 1,
                            onSkip: { decline(SdkOfferDeclineControlFreePlanLink, then: continueFree) },
                            onBack: back.map { back in { decline(SdkOfferDeclineControlBack, then: back) } }
                        )
                    }

                    Spacer().frame(height: 16)

                    Text("Welcome offer")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(introProGoldLight)
                        .textCase(.uppercase)
                        .tracking(1.2)

                    Spacer().frame(height: 8)

                    Text(String(format: String(localized: "%lld months of Pro, free"), presentation.offer?.monthsFree ?? 3))
                        .font(themeManager.currentTheme.titleFont)

                    Spacer().frame(height: 8)

                    Text(String(format: String(localized: "%lld%% off your first year"), presentation.offer?.percentOff ?? 25))
                        .font(themeManager.currentTheme.bodyFontLarge)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)

                    // room for the card's halo and pill
                    Spacer().frame(height: 40)

                    ProductOptionCard(
                        title: presentation.yearlyTitle,
                        lines: presentation.yearlyLines,
                        select: { ClientEvents.shared.offerCardTapped(plan: SdkPlanYearly) },
                        isSelected: true,
                        bestValue: true,
                        pill: presentation.yearlyPill,
                        deadline: presentation.availableUntilLine()
                    )

                    Spacer().frame(height: 24)

                    // the trial timeline: when the charge happens, and that it can be stopped before
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(timeline.enumerated()), id: \.offset) { index, row in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(index == 0 ? introProGold : themeManager.currentTheme.textFaintColor)
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label)
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    Text(row.text)
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)
                                }
                            }
                        }
                    }

                    if let purchaseError {
                        Spacer().frame(height: 16)
                        Text(purchaseError)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(.red)
                    }

                    Spacer(minLength: 24)

                    UrButton(
                        text: LocalizedStringKey(presentation.ctaTitle(for: .yearly)),
                        action: {
                            ClientEvents.shared.offerCtaTapped(plan: SdkPlanYearly)
                            startTrial()
                        },
                        enabled: !isPurchasing,
                        isProcessing: isPurchasing,
                        accessibilityIdentifier: "acceptance.introduction.offer.start"
                    )

                    if let terms = presentation.termsLine(for: .yearly) {
                        Spacer().frame(height: 10)
                        Text(terms)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }

                    Spacer().frame(height: 8)

                    // always visible: the free plan, one tap, no second offer
                    Button(action: { decline(SdkOfferDeclineControlFreePlanLink, then: continueFree) }) {
                        Text("Continue with the free plan")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("acceptance.introduction.offer.free")
                }
                .padding()
                .tabletReadableColumn()
                .frame(minHeight: proxy.size.height)
            }
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            guard shownAt == nil else { return }
            shownAt = Date()
            let price = presentation.firstYearPrice ?? presentation.yearly
            ClientEvents.shared.offerScreenShown(
                surface: surface,
                experiment: experimentId,
                variant: experimentVariant,
                tier: presentation.tier.name,
                priceShown: NSDecimalNumber(decimal: price.amount).doubleValue,
                currency: presentation.yearly.currencyCode,
                expiresInSeconds: presentation.offer.map { Int64($0.expiresAt.timeIntervalSinceNow) } ?? 0
            )
        }
    }
}

#Preview {
    IntroductionOfferView(
        presentation: .resolve(
            tier: .standard,
            offer: PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date().addingTimeInterval(5 * 86400), appleOfferCode: "ONBOARD25"),
            storeMonthly: nil,
            storeYearly: nil,
            trialDays: 14,
            equivalent: PlanEquivalent(monthlyEquivalent: 3.34, showEquivalent: true, savingPercent: 33)
        ),
        continueFree: {},
        back: {},
        startTrial: {}
    )
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
    .environmentObject(IntroConnectorState())
}
