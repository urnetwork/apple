//
//  UpgradeSubscriptionSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import SwiftUI
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif
import URnetworkSdk

struct UpgradeSubscriptionSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    /// The tier, the welcome offer and the storefront every plan surface renders from.
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel

    var monthlyProduct: Product?
    var yearlyProduct: Product?
    /// The yearly trial StoreKit says this user may get; nil promises none.
    var yearlyTrialDays: Int? = nil
    /// The welcome offer's App Store path when the offer is active (see step 5); nil buys the plan.
    var redeemOffer: ((PlanOffer) -> Void)? = nil
    /// A tap on a plan whose product has not arrived from the store (see SubscriptionPlanPrices).
    var purchaseUnavailable: () -> Void = {}
    /// The presentation the store computed (StripeSubscriptionStore); nil builds
    /// it from the StoreKit products as always.
    var presentationOverride: PlanPresentation? = nil
    var purchase: (Product) -> Void = { _ in }
    /// Buys the selected plan through a SubscriptionStore; when set, `purchase`
    /// and `purchaseUnavailable` are not used.
    var purchasePlan: ((PaymentOption) -> Void)? = nil
    /// A checkout page in progress (the direct-download build's Stripe pay
    /// sheet): shown over the plans while it is open.
    var checkout: AnyView? = nil
    var isPurchasing: Bool
    var purchaseSuccess: Bool
    /**
     * The server has confirmed the entitlement (the confirmation poll saw the
     * subscription and the jwt refreshed to pro). Until this is true,
     * `purchaseSuccess` only means StoreKit took the payment — the success
     * screen must stay processing-shaped, not premium-shaped.
     */
    var purchaseConfirmed: Bool = false
    /**
     * StoreKit accepted the purchase but it is awaiting approval (Ask to Buy) or
     * another auth step. It is NOT complete and no transaction arrives now.
     */
    var purchasePending: Bool = false
    /**
     * The confirmation poll gave up (2 minutes) without the server confirming.
     * The money was taken; the entitlement will land via the background poll or
     * a restore — but the user must be told, not left on a success screen.
     */
    var purchaseConfirmationTimedOut: Bool = false
    /**
     * Localized description of a failed purchase attempt (nil when none).
     */
    var purchaseError: String? = nil
    /**
     * The product fetch failed and there is nothing to sell; shows a retry
     * instead of the old eternal spinner.
     */
    var productsLoadFailed: Bool = false
    var retryFetchProducts: () -> Void = {}
    var restorePurchases: () -> Void = {}
    var isRestoringPurchases: Bool = false
    var restoreMessage: String? = nil
    /// The confirming screen's title and copy for a store other than the App
    /// Store; nil keeps the StoreKit copy.
    var purchaseConfirmingTitle: String? = nil
    var purchaseConfirmingMessage: String? = nil
    /// A start connect blocked by the balance opened the sheet: it leads with
    /// when the free data refreshes and offers Wait for refresh, which
    /// dismisses it (upgradeShowsFreeRefresh).
    var showsFreeRefresh: Bool = false
    var dismiss: () -> Void

    @State var selectedPaymentOption: PaymentOption = .yearly

    private var presentation: PlanPresentation {
        if let presentationOverride {
            return presentationOverride
        }
        return .current(
            monthly: monthlyProduct,
            yearly: yearlyProduct,
            tier: subscriptionBalanceViewModel.priceTier,
            offer: subscriptionBalanceViewModel.onboardingOffer,
            storefrontCountryName: subscriptionBalanceViewModel.storefrontCountryName,
            yearlyTrialDays: yearlyTrialDays
        )
    }

    /// The Pro celebration: launched once when the server confirms the purchase, over the
    /// success view.
    @EnvironmentObject var proCelebration: ProCelebrationState
    @State private var celebratedPurchase: Bool = false

    private func celebrateIfConfirmed() {
        if purchaseSuccess && purchaseConfirmed && !celebratedPurchase {
            celebratedPurchase = true
            proCelebration.launch()
        }
    }

    var body: some View {

        ZStack {

            if (purchaseSuccess) {

                PurchaseSuccessView(
                    phase: purchaseConfirmed
                        ? .confirmed
                        : (purchaseConfirmationTimedOut ? .delayed : .confirming),
                    restore: restorePurchases,
                    isRestoring: isRestoringPurchases,
                    restoreMessage: restoreMessage,
                    confirmingTitle: purchaseConfirmingTitle,
                    confirmingMessage: purchaseConfirmingMessage,
                    dismiss: dismiss
                )
                .transition(.opacity)
                .frame(maxWidth: .infinity)

            } else if let checkout {

                // the checkout page swaps in over the plans (its own header
                // carries the close), like the Windows and Linux sheets
                checkout
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)

            } else if (purchasePending) {

                /**
                 * Ask to Buy / SCA. The purchase is not done, and the transaction lands
                 * later on Transaction.updates -- so there is nothing to wait for here.
                 *
                 * This state used to be swallowed entirely: the spinner just stopped and
                 * the user was returned to the product list as if nothing had happened.
                 * The natural conclusion is that it failed, so they buy again.
                 */
                VStack(spacing: 12) {

                    Spacer()

                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(themeManager.currentTheme.textMutedColor)

                    Text("Waiting for approval")
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    Text("Your purchase needs to be approved before it can complete. UR Pro will turn on by itself once it goes through — there's no need to buy again.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Spacer()

                    UrButton(text: "Got it", action: dismiss)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity)

            } else {

                VStack {

                    if (isPurchasing) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {


                            VStack(alignment: .leading) {

                                #if os(macOS)

                                HStack {
                                    Spacer()
                                    Button(action: {
                                        dismiss()
                                    }) {
                                        Image(systemName: "xmark")
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Spacer().frame(height: 8)

                                #endif

                                HStack {
                                    Text("Get Pro")
                                        .font(themeManager.currentTheme.titleFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)

                                    Spacer()
                                }

                                // No explainer under the title: the screen is the title and
                                // the two plan options. A blocked connect is the exception:
                                // upgrading must not read as the only way back, so it says
                                // when the free data refreshes and offers to wait for it.
                                if showsFreeRefresh {
                                    Spacer().frame(height: 8)

                                    FreeRefreshCountdownText()

                                    Spacer().frame(height: 16)

                                    UrButton(
                                        text: "Wait for refresh",
                                        action: dismiss,
                                        style: .outlineSecondary,
                                        accessibilityIdentifier: "acceptance.upgrade.waitForRefresh"
                                    )
                                }

                                Spacer().frame(height: 24)

                                /**
                                 * A failed attempt renders its reason inline
                                 * (finding A5) with the manual resync beside it
                                 * (finding A3) -- a purchase can have completed
                                 * on Apple's side even when the attempt here
                                 * reported an error.
                                 */
                                if let purchaseError {

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(purchaseError)
                                            .font(themeManager.currentTheme.secondaryBodyFont)
                                            .foregroundColor(.red)

                                        Button(action: restorePurchases) {
                                            if isRestoringPurchases {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle())
                                            } else {
                                                Text("Restore purchases")
                                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        .underline()

                                        if let restoreMessage {
                                            Text(restoreMessage)
                                                .font(themeManager.currentTheme.secondaryBodyFont)
                                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        }
                                    }

                                    Spacer().frame(height: 18)
                                }

                                if productsLoadFailed {

                                    // the store did not answer; the plans still render
                                    // from their list prices, and this offers a retry
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Couldn't load subscription options. Check your connection and retry.")
                                            .font(themeManager.currentTheme.secondaryBodyFont)
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)

                                        Button(action: retryFetchProducts) {
                                            Text("Retry")
                                                .font(themeManager.currentTheme.secondaryBodyFont)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        .underline()
                                    }

                                    Spacer().frame(height: 18)
                                }

                                // room for the plan box's halo and pill
                                Spacer().frame(height: 16)

                                SubscriptionPlanPicker(
                                    presentation: presentation,
                                    selectedPaymentOption: $selectedPaymentOption,
                                    purchase: {
                                        // the active welcome offer on the yearly plan goes
                                        // through the App Store offer code; everything else
                                        // is a plain purchase
                                        if selectedPaymentOption == .yearly,
                                           let offer = presentation.offer,
                                           let redeemOffer {
                                            ClientEvents.shared.offerCtaTapped(plan: SdkPlanYearly)
                                            redeemOffer(offer)
                                            return
                                        }
                                        if let purchasePlan {
                                            purchasePlan(selectedPaymentOption)
                                            return
                                        }
                                        let product = selectedPaymentOption == .monthly
                                            ? monthlyProduct
                                            : yearlyProduct
                                        if let product {
                                            purchase(product)
                                        } else {
                                            purchaseUnavailable()
                                        }
                                    },
                                    onCardTapped: { option in
                                        if presentation.hasOffer {
                                            ClientEvents.shared.offerCardTapped(
                                                plan: option == .monthly ? SdkPlanMonthly : SdkPlanYearly
                                            )
                                        }
                                    }
                                )

                                Spacer().frame(minHeight: 18)

                                VStack(alignment: .leading) {

                                    HStack {
                                        Text("By subscribing, you agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                                            .font(themeManager.currentTheme.secondaryBodyFont)

                                        Spacer()
                                    }

                                }

                            }


                    }

                }
                .transition(.opacity)
                .padding()
                .frame(maxWidth: .infinity)

            }

        }
        .frame(maxWidth: .infinity)
        .animation(.easeIn(duration: 0.25), value: purchaseSuccess)
        // the celebration draws over the sheet, which sits above the app root
        .proCelebrationLayer()
        .onChange(of: purchaseConfirmed) { _ in
            celebrateIfConfirmed()
        }
        .onChange(of: purchaseSuccess) { success in
            if !success {
                // the flags describe one attempt; the next purchase celebrates again
                celebratedPurchase = false
            }
            celebrateIfConfirmed()
        }
        .onAppear {
            // the sheet can't be allowed to spin forever on a product fetch
            // that failed at app init -- retry when it opens
            retryFetchProducts()
            celebrateIfConfirmed()
        }

    }
}

//#Preview {
//
//    let themeManager = ThemeManager.shared
//
//    let mockProduct = MockSKProduct(
//        localizedTitle: "URnetwork Supporter",
//        localizedDescription: "Support us in building a new kind of network that gives instead of takes.",
//        price: 5.00,
//        priceLocale: Locale(identifier: "en_US")
//    )
//
//    VStack {
//        UpgradeSubscriptionSheet(
//            subscriptionProduct: mockProduct,
//            purchase: {_ in}
//        )
//    }
//    .environmentObject(themeManager)
//    .background(themeManager.currentTheme.backgroundColor)
//    .frame(maxWidth: .infinity, maxHeight: .infinity)
//
//}
