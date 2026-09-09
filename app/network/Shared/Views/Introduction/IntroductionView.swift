//
//  IntroductionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
import StoreKit
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
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectViewModel: ConnectViewModel
    /// The Pro celebration: launched once when the server confirms the onboarding purchase.
    @EnvironmentObject var proCelebration: ProCelebrationState
    @State private var celebratedPurchase: Bool = false

    private func celebrateIfConfirmed() {
        if subscriptionManager.purchaseSuccess && deviceManager.isPro && !celebratedPurchase {
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
    
    init(
        close: @escaping () -> Void,
        totalReferrals: Int,
        referralCode: String,
        meanReliabilityWeight: Double,
        api: UrApiServiceProtocol,
        referralTerms: ReferralTerms = .default
    ) {
        self.close = close
        self.totalReferrals = totalReferrals
        self.referralCode = referralCode
        self.meanReliabilityWeight = meanReliabilityWeight
        self.api = api
        self.referralTerms = referralTerms
    }
    
    /// The welcome offer's purchase: the App Store offer code through the redeem
    /// sheet, then the usual confirmation poll; with no code yet, the plain yearly
    /// purchase with the trial.
    private func redeemWelcomeOffer(_ offer: PlanOffer) {
        let yearly = yearlySubscription
        let initiallyConnected = deviceManager.device?.getConnected() ?? false
#if os(macOS)
        if (initiallyConnected) {
            connectViewModel.disconnect()
        }
#endif
        Task {
            await subscriptionManager.redeemOffer(
                code: offer.appleOfferCode,
                yearly: yearly,
                onSuccess: {
                    subscriptionBalanceViewModel.startPolling()
                }
            )
#if os(macOS)
            if (initiallyConnected) {
                connectViewModel.connect()
            }
#endif
        }
    }

    private var monthlySubscription: Product? {
        return subscriptionManager.monthlySubscription
    }
    
    private var yearlySubscription: Product? {
        return subscriptionManager.yearlySubscription
    }

    
    @State var selectedPaymentOption: PaymentOption = .yearly

    /// The plan cards on page 1: the tier's prices, the store's when loaded, and the
    /// welcome offer once it is issued.
    private var presentation: PlanPresentation {
        .current(
            monthly: monthlySubscription,
            yearly: yearlySubscription,
            tier: subscriptionBalanceViewModel.priceTier,
            offer: subscriptionBalanceViewModel.onboardingOffer,
            storefrontCountryName: subscriptionBalanceViewModel.storefrontCountryName
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

    /// Whether this run has the offer page: everyone outside the in-app holdout.
    private var offerEnabled: Bool {
        subscriptionBalanceViewModel.offerScreenEnabled
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
        
        ZStack {
            
            if (subscriptionManager.purchaseSuccess) {

                // StoreKit success is not entitlement: the copy stays
                // processing-shaped until the confirmation poll flips isPro,
                // and says so if the poll gives up (finding A2)
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
                    dismiss: close
                )
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea()

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
                                    if let offer = presentation.offer {
                                        redeemWelcomeOffer(offer)
                                    } else if let yearly = yearlySubscription {
                                        // the offer could not be issued: the plain trial
                                        Task {
                                            try? await subscriptionManager.purchase(product: yearly, onSuccess: {
                                                subscriptionBalanceViewModel.startPolling()
                                            })
                                        }
                                    } else {
                                        subscriptionManager.reportProductsUnavailable()
                                    }
                                },
                                isPurchasing: subscriptionManager.isPurchasing,
                                purchaseError: subscriptionManager.purchaseError,
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
        .animation(.easeIn(duration: 0.25), value: subscriptionManager.purchaseSuccess)
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
        .onChange(of: subscriptionManager.purchaseSuccess) { success in
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
                    
                    Text("URnetwork gives you verifiable encryption for everyday use.")
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
                                // the App Store offer code (step 5); the rest is a plain purchase
                                if selectedPaymentOption == .yearly, let offer = presentation.offer {
                                    ClientEvents.shared.offerCtaTapped(plan: SdkPlanYearly)
                                    redeemWelcomeOffer(offer)
                                    return
                                }

                                let product = selectedPaymentOption == .monthly ? monthlySubscription : yearlySubscription
                                guard let product else {
                                    // the store has not answered; say so where a failed
                                    // purchase would, and ask it again
                                    subscriptionManager.reportProductsUnavailable()
                                    return
                                }

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
                                    do {
                                        try await subscriptionManager.purchase(
                                            product: product,
                                            onSuccess: {
                                                subscriptionBalanceViewModel.startPolling()
                                            }
                                        )

                                    } catch(let error) {
                                        // rendered inline via subscriptionManager.purchaseError
                                        print("error making purchase: \(error)")
                                    }

#if os(macOS)
                                    if (initiallyConnected) {
                                        connectViewModel.connect()
                                    }
#endif

                                }

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
                            if let purchaseError = subscriptionManager.purchaseError {

                                Spacer().frame(height: 12)

                                Text(purchaseError)
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(.red)

                                Spacer().frame(height: 8)

                                Button(action: {
                                    Task {
                                        if await subscriptionManager.restorePurchases() == .restored {
                                            subscriptionBalanceViewModel.startPolling()
                                        }
                                    }
                                }) {
                                    if subscriptionManager.isRestoringPurchases {
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

                                if let restoreMessage = subscriptionManager.restoreResultMessage {
                                    Spacer().frame(height: 8)

                                    Text(restoreMessage)
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                }
                            }

                        if subscriptionManager.fetchProductsError {

                            // the store did not answer; the plans still render from
                            // their list prices, and this offers a retry
                            Spacer().frame(height: 12)

                            Text("Couldn't load subscription options. Check your connection and retry.")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)

                            Spacer().frame(height: 8)

                            Button(action: {
                                subscriptionManager.retryFetchProductsIfNeeded()
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
                        // the intro funnel can't spin forever on a
                        // product fetch that failed at app init
                        subscriptionManager.retryFetchProductsIfNeeded()
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
