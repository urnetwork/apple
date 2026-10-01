//
//  OnboardingOfferSheet.swift
//  URnetwork
//
//  The welcome offer on its own, reached from an onboarding email's offer link
//  while the offer is active: the same page as the last onboarding step, with
//  the purchase wired to the build's SubscriptionStore (the session's StoreKit
//  manager on the App Store, Stripe on the direct download) and the success
//  screen once the server confirms Pro.
//

import SwiftUI
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif
import URnetworkSdk

struct OnboardingOfferSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var stripeSubscriptionStore: StripeSubscriptionStore
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectViewModel: ConnectViewModel

    let dismiss: () -> Void

    /// Who sells Pro in this build: StoreKit on the App Store, Stripe on the
    /// direct download (see BillingDistribution).
    private var subscriptionStore: any SubscriptionStore {
        makeSubscriptionStore(for: .current, appStore: subscriptionManager, stripe: stripeSubscriptionStore)
    }

    private var presentation: PlanPresentation {
        subscriptionStore.presentation(
            tier: subscriptionBalanceViewModel.priceTier,
            offer: subscriptionBalanceViewModel.onboardingOffer,
            storefrontCountryName: subscriptionBalanceViewModel.storefrontCountryName
        ) ?? .current(
            monthly: subscriptionManager.monthlySubscription,
            yearly: subscriptionManager.yearlySubscription,
            tier: subscriptionBalanceViewModel.priceTier,
            offer: subscriptionBalanceViewModel.onboardingOffer,
            storefrontCountryName: subscriptionBalanceViewModel.storefrontCountryName,
            yearlyTrialDays: subscriptionManager.yearlyTrialDays
        )
    }

    /// The offer, or when it is no longer issued the plain yearly purchase
    /// (the trial on the App Store), through the store, then the usual
    /// confirmation poll.
    private func startTrial() {
        let subscriptionStore = self.subscriptionStore
        let purchase = OnboardingPurchase.forSelection(.yearly, offer: presentation.offer)
        let initiallyConnected = deviceManager.device?.getConnected() ?? false
        #if os(macOS)
        if initiallyConnected {
            connectViewModel.disconnect()
        }
        #endif
        Task {
            switch purchase {
            case .redeemOffer(let offer):
                await subscriptionStore.redeemOffer(offer, onSuccess: { subscriptionBalanceViewModel.startPolling() })
            case .purchase(let plan):
                await subscriptionStore.purchase(plan: plan, onSuccess: { subscriptionBalanceViewModel.startPolling() })
            }
            #if os(macOS)
            if initiallyConnected {
                connectViewModel.connect()
            }
            #endif
        }
    }

    var body: some View {
        let subscriptionStore = self.subscriptionStore
        ZStack {
            if subscriptionStore.purchaseSuccess {
                PurchaseSuccessView(
                    phase: deviceManager.isPro
                        ? .confirmed
                        : (subscriptionBalanceViewModel.purchaseConfirmationTimedOut ? .delayed : .confirming),
                    restore: {
                        Task {
                            if await subscriptionStore.restorePurchases() == .restored {
                                subscriptionBalanceViewModel.startPolling()
                            }
                        }
                    },
                    isRestoring: subscriptionStore.isRestoringPurchases,
                    restoreMessage: subscriptionStore.restoreResultMessage,
                    confirmingTitle: subscriptionStore.purchaseConfirmingTitle,
                    confirmingMessage: subscriptionStore.purchaseConfirmingMessage,
                    dismiss: {
                        subscriptionStore.resetPurchaseState()
                        dismiss()
                    }
                )
                .transition(.opacity)
            } else if let checkout = subscriptionStore.checkoutView {
                // the direct download's Stripe checkout page swaps in over the
                // offer while it is open (its own header carries the close)
                checkout
                    .transition(.opacity)
            } else {
                IntroductionOfferView(
                    presentation: presentation,
                    continueFree: dismiss,
                    startTrial: startTrial,
                    isPurchasing: subscriptionStore.isPurchasing,
                    purchaseError: subscriptionStore.purchaseError,
                    standalone: true,
                    surface: SdkOfferSurfaceEmailLink,
                    experimentId: subscriptionBalanceViewModel.offerExperimentId,
                    experimentVariant: subscriptionBalanceViewModel.offerExperimentVariant
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .environmentObject(IntroConnectorState())
        .animation(.easeIn(duration: 0.25), value: subscriptionStore.purchaseSuccess)
        .onAppear {
            // the plans the offer renders from; on the direct download this
            // is what loads the Stripe prices if nothing has yet
            subscriptionStore.retryLoadPlansIfNeeded(storefrontCountry: subscriptionBalanceViewModel.storefrontCountry)
        }
    }
}
