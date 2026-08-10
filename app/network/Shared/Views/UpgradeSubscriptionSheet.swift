//
//  UpgradeSubscriptionSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import SwiftUI
import StoreKit

struct UpgradeSubscriptionSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    var monthlyProduct: Product?
    var yearlyProduct: Product?
    var purchase: (Product) -> Void
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
    var dismiss: () -> Void

    @State var selectedPaymentOption: PaymentOption = .yearly

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
                    dismiss: dismiss
                )
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

                        if let monthly = monthlyProduct, let yearly = yearlyProduct {

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

                                Text("Become a")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                HStack {
                                    Text("URnetwork Supporter")
                                        .font(themeManager.currentTheme.titleFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)

                                    Spacer()
                                }

                                Spacer().frame(height: 24)

                                HStack {
                                    Text("Support us in building a new kind of network that gives instead of takes.")
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)

                                    Spacer()
                                }

                                Spacer().frame(height: 18)

                                HStack {

                                    Text("You’ll unlock even faster speeds, and first dibs on new features like robust anti-censorship measures and data control.")
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)

                                    Spacer()

                                }

                                Spacer().frame(height: 18)

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

                                ProductOptionCard(
                                    price: "\(yearly.displayPrice)/year",
                                    select: {
                                        selectedPaymentOption = .yearly
                                    },
                                    isSelected: selectedPaymentOption == .yearly,
                                    includesFreeTrial: true,
                                    isMostPopular: true
                                )

                                Spacer().frame(height: 18)

                                ProductOptionCard(
                                    price: "\(monthly.displayPrice)/month",
                                    select: {
                                        selectedPaymentOption = .monthly
                                    },
                                    isSelected: selectedPaymentOption == .monthly,
                                    includesFreeTrial: false,
                                    isMostPopular: false
                                )

                                Spacer().frame(minHeight: 18)

                                VStack(alignment: .leading) {

                                    UrButton(text: "Join the movement", action: {
                                        if selectedPaymentOption == .monthly {
                                            purchase(monthly)
                                        } else {
                                            purchase(yearly)
                                        }

                                    })

                                    Spacer().frame(height: 18)

                                    HStack {
                                        Text("By subscribing, you agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                                            .font(themeManager.currentTheme.secondaryBodyFont)

                                        Spacer()
                                    }

                                }

                            }

                        } else if productsLoadFailed {

                            /**
                             * The init-time product fetch failed and was never
                             * retried, so this branch used to be an eternal
                             * spinner (finding A5). Say what happened and let
                             * the user retry; restore stays available for a
                             * user whose purchase already exists.
                             */
                            VStack(spacing: 12) {

                                Spacer()

                                Text("Couldn't load subscription options. Check your connection and retry.")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)

                                UrButton(
                                    text: "Retry",
                                    action: retryFetchProducts
                                )
                                .padding(.horizontal, 16)

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
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                }

                                Spacer()
                            }

                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
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
        .onAppear {
            // the sheet can't be allowed to spin forever on a product fetch
            // that failed at app init -- retry when it opens
            retryFetchProducts()
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
