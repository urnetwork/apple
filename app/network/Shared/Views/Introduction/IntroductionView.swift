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
            expectedRoute = nil
        }

        guard route == expectedRoute else { return }
        path.append(route)
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
    
    init(close: @escaping () -> Void, totalReferrals: Int, referralCode: String, meanReliabilityWeight: Double, api: UrApiServiceProtocol) {
        self.close = close
        self.totalReferrals = totalReferrals
        self.referralCode = referralCode
        self.meanReliabilityWeight = meanReliabilityWeight
        self.api = api
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
                    
                    ScrollView {
                        
                        VStack(alignment: .leading) {
                            
                            Text("Welcome to URnetwork")
                                .font(themeManager.currentTheme.titleFont)
                            
                            Spacer().frame(height: 8)
                            
                            Text("URnetwork is the most local and most private network on the planet.")
                                .font(themeManager.currentTheme.bodyFontLarge)
                            
                            Spacer().frame(height: 32)
                            
                            // points
                            IntroBulletPoint(text: "100% open source and transparent")
                            
                            IntroBulletPoint(text: "Lowest user/IP ratio to access content")
                            
                            IntroBulletPoint(text: "Trusted by over 100,000 private networks")
                            
                            Spacer().frame(height: 24)
                            
                            /**
                             * Upgrade prompt
                             */
                            VStack(alignment: .leading) {
                                
                                if let monthly = monthlySubscription, let yearly = yearlySubscription {
                                    
                                    ProductOptionCard(
                                        price: "\(yearly.displayPrice) Annual (Save 33%)",
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
                                    
                                    Spacer().frame(height: 18)
                                    
                                    UrButton(
                                        text: selectedPaymentOption == .monthly
                                            ? "Join the movement"
                                            : "Start 2 week free trial",
                                        action: {
                                        
                                        let product = selectedPaymentOption == .monthly ? monthly : yearly

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
                                                        // subscriptionBalanceViewModel.setCurrentPlan(.supporter)
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

//                                    Button("Redeem Balance Code", action: {presentRedeemBalanceCodeSheet = true})

                                } else if subscriptionManager.fetchProductsError {

                                    // the init-time product fetch failed; this
                                    // used to be an eternal spinner (finding A5)
                                    VStack(alignment: .center, spacing: 12) {
                                        Text("Couldn't load subscription options. Check your connection and retry.")
                                            .font(themeManager.currentTheme.bodyFont)
                                            .multilineTextAlignment(.center)

                                        UrButton(
                                            text: "Retry",
                                            action: {
                                                subscriptionManager.retryFetchProductsIfNeeded()
                                            }
                                        )
                                    }
                                    .frame(maxWidth: .infinity)

                                } else {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                }

                            }
                            .onAppear {
                                // the intro funnel can't spin forever on a
                                // product fetch that failed at app init
                                subscriptionManager.retryFetchProductsIfNeeded()
                            }
                            
                            Spacer().frame(height: 16)
                            
                            HStack {
                                Spacer()
                                Text("or")
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                Spacer()
                            }
                            
                            Spacer().frame(height: 16)
                            
                            /**
                             * Participate flow
                             */
                            Button(action: {
                                routeState.advance(to: .usage)
                            }) {
                                VStack(alignment: .center) {
                                    Text("Community Edition")
                                        .font(themeManager.currentTheme.toolbarTitleFont)
                                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                    
                                    Spacer().frame(height: 4)
                                    
                                    
                                    Text("Get free access to the community edition.")
                                        .font(Font.custom("PP NeueBit", size: 18).weight(.bold))
                                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity)
                                // Plain buttons otherwise hit-test only their
                                // rendered text, while accessibility exposes
                                // this entire card as the button frame.
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(themeManager.currentTheme.textFaintColor, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("acceptance.introduction.community")
                            
                            Spacer().frame(height: 16)
                            
                            /**
                             * Redeem balance code prompt
                             */
                            
                            VStack(alignment: .center) {
                                Text("Redeem Balance Code")
                                    .font(themeManager.currentTheme.toolbarTitleFont)
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(themeManager.currentTheme.textFaintColor, lineWidth: 1)
                            )
                            .onTapGesture {
                                presentRedeemBalanceCodeSheet = true
                            }
                            
                            Spacer().frame(height: 32)
                            
                            HStack(alignment: .center) {
                                Text("""
                                URnetwork is powered by the world's largest, safest,
                                and most decentralized ingress and egress protocol.
                                """)
                                    .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)

                            Spacer()
                        }
                        .padding()
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: close) {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close")
                        }
                    }
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
                                totalReferrals: totalReferrals,
                                referralCode: referralCode
                            )
                        }
                    }
                }
                
            }
            
        }
        .animation(.easeIn(duration: 0.25), value: subscriptionManager.purchaseSuccess)
        .animation(.easeIn(duration: 0.25), value: balanceCodeRedeemed)
        
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
