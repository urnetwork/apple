//
//  IntroductionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
import StoreKit

enum IntroductionRoute: Hashable {
    case usage
    case participate
    case refer
    case quickConnect
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
            expectedRoute = nil
        }

        guard route == expectedRoute else { return }
        path.append(route)
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
    
    private var monthlySubscription: Product? {
        return subscriptionManager.monthlySubscription
    }
    
    private var yearlySubscription: Product? {
        return subscriptionManager.yearlySubscription
    }

    
    @State var selectedPaymentOption: PaymentOption = .yearly
    @State var presentRedeemBalanceCodeSheet: Bool = false
    @State var balanceCodeRedeemed: Bool = false
    @State private var routeState = IntroductionRouteState()
    // the connector mark that flies from page 1's route line into the header
    @StateObject private var introConnector = IntroConnectorState()
    
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
                                close: close,
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
                                close: close,
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
                                close: close,
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
                                close: close,
                                back: { routeState.back() }
                            )
                        }
                    }
                }

                FloatingIntroConnector(state: introConnector)
                
            }
            
        }
        .coordinateSpace(name: IntroConnectorState.coordinateSpace)
        .environmentObject(introConnector)
        .environment(\.introConnector, introConnector)
        .onChange(of: routeState.path) { path in
            let inHeader = !path.isEmpty
            if introConnector.inHeader != inHeader {
                introConnector.inHeader = inHeader
            }
        }
        .animation(.easeIn(duration: 0.25), value: subscriptionManager.purchaseSuccess)
        .animation(.easeIn(duration: 0.25), value: balanceCodeRedeemed)
        
    }

    // MARK: Page 1

    private var welcomePage: some View {
        GeometryReader { proxy in
            ScrollView {
                
                VStack(alignment: .leading, spacing: 0) {

                    IntroductionTopBar(step: 1, onSkip: close)

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
                                monthly: monthlySubscription,
                                yearly: yearlySubscription,
                                selectedPaymentOption: $selectedPaymentOption,
                                purchase: {

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
