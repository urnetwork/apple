//
//  IntroductionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
// StoreKit is not linked in the direct-download build (Stripe billing; see BillingDistribution)
#if !DIRECT_DOWNLOAD
import StoreKit
#endif
import URnetworkSdk

enum IntroductionRoute: Hashable {
    case usage
    case participate
    case refer
    case quickConnect
    /// The welcome offer, the last page everyone reaches (Skip lands here too).
    case offer
}

struct IntroductionRouteState: Equatable {
    var path: [IntroductionRoute] = []

    mutating func advance(to route: IntroductionRoute) {
        let expectedRoute: IntroductionRoute?
        switch path.last {
        case nil:
            expectedRoute = .usage
        case .usage:
            expectedRoute = .participate
        case .participate:
            expectedRoute = .refer
        case .refer:
            expectedRoute = .quickConnect
        case .quickConnect:
            expectedRoute = .offer
        case .offer:
            expectedRoute = nil
        }

        guard route == expectedRoute else { return }
        path.append(route)
    }

    /// Skip from any earlier page lands on the offer page, once: the offer
    /// page's own controls leave the flow, so a second skip is impossible.
    mutating func skipToOffer() {
        guard path.last != .offer else { return }
        path.append(.offer)
    }

    var isOnOffer: Bool {
        path.last == .offer
    }

    mutating func back() {
        _ = path.popLast()
    }
}


struct IntroductionView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var stripeSubscriptionStore: StripeSubscriptionStore
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectViewModel: ConnectViewModel
    /// The Pro celebration: launched once when the server confirms the onboarding purchase.
    @EnvironmentObject var proCelebration: ProCelebrationState
    @State private var celebratedPurchase: Bool = false

    /// Who sells Pro in this build: StoreKit on the App Store, Stripe on the
    /// direct download (see BillingDistribution). The plans, the purchase and
    /// the per-attempt state all come from it.
    private var subscriptionStore: any SubscriptionStore {
        makeSubscriptionStore(for: .current, appStore: subscriptionManager, stripe: stripeSubscriptionStore)
    }

    private func celebrateIfConfirmed() {
        if subscriptionStore.purchaseSuccess && deviceManager.isPro && !celebratedPurchase {
            celebratedPurchase = true
            proCelebration.launch()
        }
    }
    
    let close: () -> Void
    let totalReferrals: Int
    let referralCode: String
    let meanReliabilityWeight: Double
    let api: UrApiServiceProtocol
    let referralTerms: ReferralTerms
    let referralCodeLoadFailed: Bool
    let retryReferralCode: (() -> Void)?
    
    init(
        close: @escaping () -> Void,
        totalReferrals: Int,
        referralCode: String,
        meanReliabilityWeight: Double,
        api: UrApiServiceProtocol,
        referralTerms: ReferralTerms = .default,
        referralCodeLoadFailed: Bool = false,
        retryReferralCode: (() -> Void)? = nil
    ) {
        self.close = close
        self.totalReferrals = totalReferrals
        self.referralCode = referralCode
        self.meanReliabilityWeight = meanReliabilityWeight
        self.api = api
        self.referralTerms = referralTerms
        self.referralCodeLoadFailed = referralCodeLoadFailed
        self.retryReferralCode = retryReferralCode
    }
    
    /// A purchase through the build's store (the welcome offer on the yearly
    /// plan, or a plain plan), then the usual confirmation poll: the server
    /// only believes the store's webhook. Errors render inline through the
    /// store's purchaseError.
    private func start(_ purchase: OnboardingPurchase) {
        let subscriptionStore = self.subscriptionStore
        let initiallyConnected = deviceManager.device?.getConnected() ?? false
#if os(macOS)
        // purchase fails in mac app store if vpn is connected;
        // iOS App Store traffic does not ride the tunnel, so only
        // macOS disconnects around the purchase — see the A6 note
        // on AppStoreSubscriptionManager.purchase
        if (initiallyConnected) {
            connectViewModel.disconnect()
        }
#endif
        Task {
            switch purchase {
            case .redeemOffer(let offer):
                await subscriptionStore.redeemOffer(offer, onSuccess: {
                    subscriptionBalanceViewModel.startPolling()
                })
            case .purchase(let plan):
                await subscriptionStore.purchase(plan: plan, onSuccess: {
                    subscriptionBalanceViewModel.startPolling()
                })
            }
#if os(macOS)
            if (initiallyConnected) {
                connectViewModel.connect()
            }
#endif
        }
    }

    private func restorePurchases() {
        let subscriptionStore = self.subscriptionStore
        Task {
            if await subscriptionStore.restorePurchases() == .restored {
                subscriptionBalanceViewModel.startPolling()
            }
        }
    }


    @State var selectedPaymentOption: PaymentOption = .yearly

    /// The plan cards on page 1: the store's plans (the Stripe prices on the
    /// direct download), or the tier's prices, the StoreKit products when
    /// loaded and the welcome offer once it is issued.
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

    @State var presentRedeemBalanceCodeSheet: Bool = false
    @State var balanceCodeRedeemed: Bool = false
    @State private var routeState = IntroductionRouteState()
    // the connector mark that flies from page 1's route line into the header
    @StateObject private var introConnector = IntroConnectorState()
    // the step the last route change skipped from, so it is not also counted as completed
    @State private var skippedStep: IntroStep? = nil
    @State private var introOfferShownReported = false

    /// Whether this run has the offer page: everyone outside the in-app holdout;
    /// on the direct download only once the Stripe prices say the welcome
    /// offer is redeemable (see WelcomeOfferSurface).
    private var offerEnabled: Bool {
        WelcomeOfferSurface.pageEnabled(
            distribution: .current,
            offerScreenEnabled: subscriptionBalanceViewModel.offerScreenEnabled,
            offerIssued: subscriptionBalanceViewModel.onboardingOffer != nil,
            stripeOfferEligible: stripeSubscriptionStore.offerEligible
        )
    }

    private var currentStep: IntroStep {
        routeState.path.last.flatMap(IntroStep.init(route:)) ?? .welcome
    }

    /// Skip from any page: the offer page, once, for everyone who has one; out of
    /// the flow for the holdout and from the offer page itself.
    private func skip() {
        let step = currentStep
        ClientEvents.shared.stepSkipped(step)
        if offerEnabled && !routeState.isOnOffer {
            skippedStep = step
            routeState.skipToOffer()
        } else {
            close()
        }
    }

    /// The end of the community pages: the offer page, or out for the holdout.
    private func finishCommunityPages() {
        if offerEnabled {
            routeState.advance(to: .offer)
        } else {
            ClientEvents.shared.stepCompleted(.quickConnect)
            close()
        }
    }
    
    var body: some View {
        
        // the store's per-attempt state, read once per render
        let subscriptionStore = self.subscriptionStore

        ZStack {

            if (subscriptionStore.purchaseSuccess) {

                // the store's success is not entitlement: the copy stays
                // processing-shaped until the confirmation poll flips isPro,
                // and says so if the poll gives up (finding A2)
                PurchaseSuccessView(
                    phase: deviceManager.isPro
                        ? .confirmed
                        : (subscriptionBalanceViewModel.purchaseConfirmationTimedOut ? .delayed : .confirming),
                    restore: restorePurchases,
                    isRestoring: subscriptionStore.isRestoringPurchases,
                    restoreMessage: subscriptionStore.restoreResultMessage,
                    confirmingTitle: subscriptionStore.purchaseConfirmingTitle,
                    confirmingMessage: subscriptionStore.purchaseConfirmingMessage,
                    dismiss: close
                )
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea()

            } else if let checkout = subscriptionStore.checkoutView {

                // the direct download's Stripe checkout page swaps in over the
                // flow while it is open (its own header carries the close)
                checkout
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)

            } else if (balanceCodeRedeemed) {

                PurchaseSuccessView(dismiss: close)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea()

            } else {
        
                NavigationStack(path: $routeState.path) {
                    
                    welcomePage
                    .navigationBarBackButtonHidden(true)
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                    .sheet(isPresented: $presentRedeemBalanceCodeSheet) {
                        VStack {
                         
                            RedeemBalanceCodeSheet(
                                closeSheet: {
                                    presentRedeemBalanceCodeSheet = false
                                },
                                onSuccess: {
                                    
                                    presentRedeemBalanceCodeSheet = false
                                    
                                    // start polling
                                    subscriptionBalanceViewModel.startPolling()
                                    
                                    Task {
                                        // Wait approx. 300ms for the sheet to animate out and keyboard to dismiss
                                        try? await Task.sleep(for: .milliseconds(300))
                                        self.balanceCodeRedeemed = true
                                    }
                                },
                                api: api
                            )
                            
                        }
                        .background(themeManager.currentTheme.backgroundColor)
                    }
                    .navigationDestination(for: IntroductionRoute.self) { route in
                        switch route {
                        case .usage:
                            IntroductionUsageBar(
                                close: skip,
                                back: { routeState.back() },
                                totalReferrals: totalReferrals,
                                referralCode: referralCode,
                                meanReliabilityWeight: meanReliabilityWeight,
                                continueAction: {
                                    routeState.advance(to: .participate)
                                }
                            )
                        case .participate:
                            IntroductionParticipateSettingsView(
                                close: skip,
                                back: { routeState.back() },
                                totalReferrals: totalReferrals,
                                referralCode: referralCode,
                                meanReliabilityWeight: meanReliabilityWeight,
                                continueAction: {
                                    routeState.advance(to: .refer)
                                }
                            )
                        case .refer:
                            ParticipateReferView(
                                close: skip,
                                back: { routeState.back() },
                                totalReferrals: totalReferrals,
                                referralCode: referralCode,
                                terms: referralTerms,
                                referralCodeLoadFailed: referralCodeLoadFailed,
                                retryReferralCode: retryReferralCode,
                                continueAction: {
                                    routeState.advance(to: .quickConnect)
                                }
                            )
                        case .quickConnect:
                            IntroductionQuickConnectView(
                                close: skip,
                                back: { routeState.back() },
                                continueAction: finishCommunityPages
                            )
                        case .offer:
                            IntroductionOfferView(
                                presentation: presentation,
                                continueFree: close,
                                back: { routeState.back() },
                                startTrial: {
                                    // the offer, or when it could not be issued the
                                    // plain yearly purchase (the trial on the App Store)
                                    start(.forSelection(.yearly, offer: presentation.offer))
                                },
                                isPurchasing: subscriptionStore.isPurchasing,
                                purchaseError: subscriptionStore.purchaseError,
                                experimentId: subscriptionBalanceViewModel.offerExperimentId,
                                experimentVariant: subscriptionBalanceViewModel.offerExperimentVariant
                            )
                            .onAppear {
                                // the page restates the offer issued on page 1; a user who
                                // skipped page 1 before it was issued gets it here
                                Task { await subscriptionBalanceViewModel.issueOnboardingOffer(surface: SdkOfferSurfaceFinalScreen) }
                            }
                        }
                    }
                }

                FloatingIntroConnector(state: introConnector)
                
            }
            
        }
        .coordinateSpace(name: IntroConnectorState.coordinateSpace)
        .environmentObject(introConnector)
        .environment(\.introConnector, introConnector)
        .environment(\.introductionTotalSteps, offerEnabled ? introductionStepCount : introductionStepCount - 1)
        .onChange(of: routeState.path) { [previousPath = routeState.path] path in
            let inHeader = !path.isEmpty
            if introConnector.inHeader != inHeader {
                introConnector.inHeader = inHeader
            }
            // the step events: forward = the page before completed (unless it was
            // skipped) and the new page shown; back = the page shown again
            let previous = previousPath.last.flatMap(IntroStep.init(route:)) ?? .welcome
            let current = path.last.flatMap(IntroStep.init(route:)) ?? .welcome
            if path.count > previousPath.count {
                if skippedStep == previous {
                    skippedStep = nil
                } else {
                    ClientEvents.shared.stepCompleted(previous)
                }
            }
            ClientEvents.shared.stepShown(current)
        }
        .onAppear {
            ClientEvents.shared.stepShown(.welcome)
            // page 1 shows the welcome offer: issue it for everyone outside the holdout
            Task { await subscriptionBalanceViewModel.issueOnboardingOffer(surface: SdkOfferSurfaceIntroStep) }
        }
        .onChange(of: subscriptionBalanceViewModel.onboardingOffer) { offer in
            reportIntroOfferShownIfNeeded(offer)
        }
        .onChange(of: subscriptionBalanceViewModel.offerScreenEnabled) { _ in
            // the balance can land after page 1 appeared
            Task { await subscriptionBalanceViewModel.issueOnboardingOffer(surface: SdkOfferSurfaceIntroStep) }
        }
        .animation(.easeIn(duration: 0.25), value: subscriptionStore.purchaseSuccess)
        .animation(.easeIn(duration: 0.25), value: balanceCodeRedeemed)
        // Over the onboarding cover, which sits above the app root. Same clear
        // overlay as the root: the body below carries a NavigationStack, which
        // is UIKit-backed on iOS and so cannot be rendered into the raster
        // layer the pixelation needs. A fresh install is the first thing that
        // hits this path.
        .overlay(
            Color.clear
                .proCelebrationLayer()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .onChange(of: deviceManager.isPro) { _ in
            celebrateIfConfirmed()
        }
        .onChange(of: subscriptionStore.purchaseSuccess) { success in
            if !success {
                celebratedPurchase = false
            }
            celebrateIfConfirmed()
        }
        
    }

    /// The offer on page 1 counts as shown once, when it is on screen there.
    private func reportIntroOfferShownIfNeeded(_ offer: PlanOffer?) {
        guard let offer, !introOfferShownReported, routeState.path.isEmpty else { return }
        introOfferShownReported = true
        let price = presentation.firstYearPrice ?? presentation.yearly
        ClientEvents.shared.offerScreenShown(
            surface: SdkOfferSurfaceIntroStep,
            experiment: subscriptionBalanceViewModel.offerExperimentId,
            variant: subscriptionBalanceViewModel.offerExperimentVariant,
            tier: presentation.tier.name,
            priceShown: NSDecimalNumber(decimal: price.amount).doubleValue,
            currency: presentation.yearly.currencyCode,
            expiresInSeconds: Int64(offer.expiresAt.timeIntervalSinceNow)
        )
    }

    // MARK: Page 1

    private var welcomePage: some View {
        GeometryReader { proxy in
            ScrollView {
                
                VStack(alignment: .leading, spacing: 0) {

                    IntroductionTopBar(step: 1, onSkip: skip)

                    Spacer().frame(height: 16)

                    IntroTraveller()

                    Spacer().frame(height: 20)
                    
                    Text("Welcome to URnetwork")
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 16)
                    
                    Text("Encryption for everyday use.")
                        .font(themeManager.currentTheme.bodyFontLarge)
                    
                    // room for the plan box's halo and pill, and air between it and the tagline
                    Spacer().frame(height: 52)
                    
                    /**
                     * Upgrade prompt
                     */
                    VStack(alignment: .leading) {
                        
                            
                            SubscriptionPlanPicker(
                                presentation: presentation,
                                selectedPaymentOption: $selectedPaymentOption,
                                purchase: {

                                // the active welcome offer on the yearly plan goes through
                                // the store's offer path (the App Store offer code, step 5;
                                // the Stripe coupon); the rest is a plain purchase. A plan
                                // whose product has not arrived is the store's to report.
                                let purchase = OnboardingPurchase.forSelection(selectedPaymentOption, offer: presentation.offer)
                                if case .redeemOffer = purchase {
                                    ClientEvents.shared.offerCtaTapped(plan: SdkPlanYearly)
                                }
                                start(purchase)

                            },
                            onCardTapped: { option in
                                if presentation.hasOffer {
                                    ClientEvents.shared.offerCardTapped(
                                        plan: option == .monthly ? SdkPlanMonthly : SdkPlanYearly
                                    )
                                }
                            })

                            /**
                             * A failed attempt renders its reason
                             * inline (finding A5), with the manual
                             * resync beside it (finding A3).
                             */
                            if let purchaseError = subscriptionStore.purchaseError {

                                Spacer().frame(height: 12)

                                Text(purchaseError)
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(.red)

                                Spacer().frame(height: 8)

                                Button(action: restorePurchases) {
                                    if subscriptionStore.isRestoringPurchases {
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

                                if let restoreMessage = subscriptionStore.restoreResultMessage {
                                    Spacer().frame(height: 8)

                                    Text(restoreMessage)
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                }
                            }

                        if subscriptionStore.plansLoadFailed {

                            // the store did not answer; the plans still render from
                            // their list prices, and this offers a retry
                            Spacer().frame(height: 12)

                            Text("Couldn't load subscription options. Check your connection and retry.")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)

                            Spacer().frame(height: 8)

                            Button(action: {
                                subscriptionStore.retryLoadPlansIfNeeded(storefrontCountry: subscriptionBalanceViewModel.storefrontCountry)
                            }) {
                                Text("Retry")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .underline()
                        }

                    }
                    .onAppear {
                        // the intro funnel can't spin forever on a product
                        // fetch that failed at app init; on the direct
                        // download this is what loads the Stripe prices
                        subscriptionStore.retryLoadPlansIfNeeded(storefrontCountry: subscriptionBalanceViewModel.storefrontCountry)
                    }
                    
                    Spacer(minLength: 24)

                    /**
                     * The other ways in, as quiet links at the bottom: the
                     * screen is about starting the free trial.
                     */
                    VStack(alignment: .center, spacing: 4) {

                        Button(action: {
                            routeState.advance(to: .usage)
                        }) {
                            Text("Community Edition")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("acceptance.introduction.community")

                        Button(action: {
                            presentRedeemBalanceCodeSheet = true
                        }) {
                            Text("Redeem Balance Code")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                // tablets: a readable centered column, not the full width
                .tabletReadableColumn()
                .frame(minHeight: proxy.size.height)
            }
        }
    }
}



#Preview {
    IntroductionView(
        close: {},
        totalReferrals: 4,
        referralCode: "ABC123",
        meanReliabilityWeight: 2.0,
        api: MockUrApiService(),
    )
}
