//
//  OnboardingOfferSheet.swift
//  URnetwork
//
//  The welcome offer on its own, reached from an onboarding email's offer link
//  while the offer is active: the same page as the last onboarding step, with
//  the purchase wired to the session's StoreKit manager and the success screen
//  once the server confirms Pro.
//

import SwiftUI
import StoreKit
import URnetworkSdk

struct OnboardingOfferSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectViewModel: ConnectViewModel

    let dismiss: () -> Void

    private var presentation: PlanPresentation {
        .current(
            monthly: subscriptionManager.monthlySubscription,
            yearly: subscriptionManager.yearlySubscription,
            tier: subscriptionBalanceViewModel.priceTier,
            offer: subscriptionBalanceViewModel.onboardingOffer,
            storefrontCountryName: subscriptionBalanceViewModel.storefrontCountryName
        )
    }

    private func startTrial() {
        let yearly = subscriptionManager.yearlySubscription
        let initiallyConnected = deviceManager.device?.getConnected() ?? false
        #if os(macOS)
        if initiallyConnected {
            connectViewModel.disconnect()
        }
        #endif
        Task {
            await subscriptionManager.redeemOffer(
                code: presentation.offer?.appleOfferCode ?? "",
                yearly: yearly,
                onSuccess: { subscriptionBalanceViewModel.startPolling() }
            )
            #if os(macOS)
            if initiallyConnected {
                connectViewModel.connect()
            }
            #endif
        }
    }

    var body: some View {
        ZStack {
            if subscriptionManager.purchaseSuccess {
                PurchaseSuccessView(
                    phase: deviceManager.isPro
                        ? .confirmed
                        : (subscriptionBalanceViewModel.purchaseConfirmationTimedOut ? .delayed : .confirming),
                    restore: {
                        Task {
                            if await subscriptionManager.restorePurchases() == .restored {
                                subscriptionBalanceViewModel.startPolling()
                            }
                        }
                    },
                    isRestoring: subscriptionManager.isRestoringPurchases,
                    restoreMessage: subscriptionManager.restoreResultMessage,
                    dismiss: {
                        subscriptionManager.resetPurchaseState()
                        dismiss()
                    }
                )
                .transition(.opacity)
            } else {
                IntroductionOfferView(
                    presentation: presentation,
                    continueFree: dismiss,
                    startTrial: startTrial,
                    isPurchasing: subscriptionManager.isPurchasing,
                    purchaseError: subscriptionManager.purchaseError,
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
        .animation(.easeIn(duration: 0.25), value: subscriptionManager.purchaseSuccess)
    }
}
