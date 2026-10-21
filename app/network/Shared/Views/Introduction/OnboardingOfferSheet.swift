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
    #if DIRECT_DOWNLOAD
    /// The direct-download build's crypto invoice (the method row's coins).
    @EnvironmentObject var cryptoInvoiceStore: CryptoInvoiceStore
    #endif

    let dismiss: () -> Void

    /// The store's purchase, or (the direct-download build) a crypto invoice, went through.
    private var succeeded: Bool {
        #if DIRECT_DOWNLOAD
        return subscriptionStore.purchaseSuccess || cryptoInvoiceStore.purchaseSucceeded
        #else
        return subscriptionStore.purchaseSuccess
        #endif
    }

    /// The success view's line while the server confirms.
    private var confirmingMessage: String? {
        #if DIRECT_DOWNLOAD
        if !subscriptionStore.purchaseSuccess && cryptoInvoiceStore.purchaseSucceeded {
            return CryptoPayCopy.confirmingMessage
        }
        #endif
        return subscriptionStore.purchaseConfirmingMessage
    }

    /// The crypto invoice shows over the offer (the direct-download build).
    private var showsCryptoInvoice: Bool {
        #if DIRECT_DOWNLOAD
        return cryptoInvoiceStore.isPresented
        #else
        return false
        #endif
    }

    /// The method row (the direct-download build): Card, and the coins the
    /// server lists for the offer's year.
    private var methodRow: PaymentMethodRowState {
        #if DIRECT_DOWNLOAD
        return cryptoInvoiceStore.methodRow(
            listed: subscriptionBalanceViewModel.cryptoPaymentMethods(offerActive: presentation.offer != nil)
        )
        #else
        return .card
        #endif
    }

    /// The failed attempt's words: the store's, else a refused crypto start's.
    private var failureMessage: String? {
        #if DIRECT_DOWNLOAD
        return subscriptionStore.purchaseError ?? cryptoInvoiceStore.refusal.map(CryptoPayCopy.refusal)
        #else
        return subscriptionStore.purchaseError
        #endif
    }

    /// Closes the sheet; the purchase state describes one attempt.
    private func close() {
        subscriptionStore.resetPurchaseState()
        #if DIRECT_DOWNLOAD
        cryptoInvoiceStore.resetPurchaseState()
        #endif
        dismiss()
    }

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
        // the restore after the store is for this device only
        let purchaseDevice = connectViewModel.device
        #if os(macOS)
        if initiallyConnected {
            connectViewModel.disconnect()
        }
        #endif
        Task {
            #if os(macOS)
            // the disconnect reaches the sdk before the store opens
            if initiallyConnected {
                await connectViewModel.connectCommandsSettled()
            }
            #endif
            switch purchase {
            case .redeemOffer(let offer):
                await subscriptionStore.redeemOffer(offer, onSuccess: { subscriptionBalanceViewModel.startPolling() })
            case .purchase(let plan):
                await subscriptionStore.purchase(plan: plan, onSuccess: { subscriptionBalanceViewModel.startPolling() })
            }
            #if os(macOS)
            if initiallyConnected {
                connectViewModel.restoreConnect(onDevice: purchaseDevice)
            }
            #endif
        }
    }

    var body: some View {
        let subscriptionStore = self.subscriptionStore
        ZStack {
            if succeeded {
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
                    confirmingMessage: confirmingMessage,
                    dismiss: close
                )
                .transition(.opacity)
            } else if showsCryptoInvoice {
                #if DIRECT_DOWNLOAD
                // the crypto invoice swaps in over the offer, like the
                // checkout page; closing it keeps it (the account screen
                // reopens it)
                CryptoInvoiceView(store: cryptoInvoiceStore)
                    .transition(.opacity)
                #endif
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
                    purchaseError: failureMessage,
                    standalone: true,
                    surface: SdkOfferSurfaceEmailLink,
                    experimentId: subscriptionBalanceViewModel.offerExperimentId,
                    experimentVariant: subscriptionBalanceViewModel.offerExperimentVariant,
                    methodRow: methodRow,
                    chooseMethod: { method in
                        #if DIRECT_DOWNLOAD
                        cryptoInvoiceStore.choose(method)
                        #endif
                    },
                    payWithCoin: { method in
                        #if DIRECT_DOWNLOAD
                        // the offer's year with a coin: the invoice, never the
                        // store, and the VPN stays up (the wallet pays outside
                        // the app). The offer page recorded the tap.
                        cryptoInvoiceStore.startInvoice(
                            method,
                            plan: PaymentMethodRules.coinPlan(offerActive: presentation.offer != nil),
                            storefrontCountry: subscriptionBalanceViewModel.storefrontCountry
                        )
                        #endif
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .environmentObject(IntroConnectorState())
        .animation(.easeIn(duration: 0.25), value: succeeded)
        .onAppear {
            // the plans the offer renders from; on the direct download this
            // is what loads the Stripe prices if nothing has yet
            subscriptionStore.retryLoadPlansIfNeeded(storefrontCountry: subscriptionBalanceViewModel.storefrontCountry)
            #if DIRECT_DOWNLOAD
            // a crypto invoice in progress shows before the offer
            if cryptoInvoiceStore.resume() {
                cryptoInvoiceStore.presentInvoice()
            }
            #endif
        }
        #if DIRECT_DOWNLOAD
        .onDisappear {
            // the success state describes one purchase
            cryptoInvoiceStore.resetPurchaseState()
        }
        #endif
    }
}
