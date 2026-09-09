//
//  MainTabView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

#if os(iOS)
struct MainTabView: View {
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let device: SdkDeviceRemote
    let logout: () -> Void
    let introductionComplete: Binding<Bool>
    let isPro: Bool
    
    @State private var opacity: Double = 0
    @StateObject var providerListSheetViewModel: ProviderListSheetViewModel = ProviderListSheetViewModel()
    
    @StateObject var networkUserViewModel: NetworkUserViewModel
    @StateObject var referralLinkViewModel: ReferralLinkViewModel
    @StateObject private var networkReliabilityStore: NetworkReliabilityStore
    
    @ObservedObject var providerListStore: ProviderListStore
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var connectViewModel: ConnectViewModel
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @Environment(\.presentationActive) private var presentationActive
    
    @State private var selectedTab = 0
    @State private var displayIntroduction: Bool
    // an email's offer link: the welcome offer on its own, while it is active
    @State private var presentOnboardingOffer = false
    // increments when the connect tab is tapped while already selected,
    // which collapses the connect drawer
    @State private var connectTabReselectCount = 0
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        providerStore: ProviderListStore,
        introductionComplete: Binding<Bool>,
//        currentPlan: Plan?,
        errorFetchingSubscriptionBalance: Bool,
        isPro: Bool
    ) {
        self.api = api
        self.urApiService = urApiService
        self.logout = logout
        self.device = device

        self.providerListStore = providerStore
        self.isPro = isPro
        _networkUserViewModel = StateObject(wrappedValue: NetworkUserViewModel(api: api))
        
        _referralLinkViewModel = StateObject(wrappedValue: ReferralLinkViewModel(api: api))
        
        _networkReliabilityStore = StateObject(wrappedValue: NetworkReliabilityStore(api: urApiService))
        
        self.introductionComplete = introductionComplete
        
        /**
         * Prompt introduction
         */
        self.displayIntroduction = IntroductionGate.shouldDisplay(
            introductionComplete: introductionComplete.wrappedValue,
            isPro: isPro,
            balanceUnavailable: errorFetchingSubscriptionBalance
        )
        
        setupTabBar()
    }
    
    var body: some View {

        ZStack {

        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == 0 {
                    selectConnectTab()
                } else {
                    selectedTab = newValue
                }
            }
        )) {

            /**
             * Connect View
             */
            ConnectView_iOS(
                api: api,
                urApiService: urApiService,
                logout: logout,
                device: device,
                providerListSheetViewModel: providerListSheetViewModel,
                referralLinkViewModel: referralLinkViewModel,
                providerStore: self.providerListStore,
                promptMoreDataFlow: {
                    self.displayIntroduction = true
                },
                meanReliabilityWeight: networkReliabilityStore.reliabilityWindow?.meanReliabilityWeight ?? 0,
                isPro: isPro,
                collapseDrawerSignal: connectTabReselectCount
            )
            .background(themeManager.currentTheme.backgroundColor)
            .tabItem {
                VStack {
                    Image(selectedTab == 0 ? "ur.symbols.tab.connect.fill" : "ur.symbols.tab.connect")
                        .renderingMode(.template)

                    Text("Connect")
        
                }
                .foregroundColor(themeManager.currentTheme.textColor)
                
            }
            .tag(0)
            
            /**
             * Account View
             */
            AccountNavStackView(
                api: api,
                urApiService: urApiService,
                device: device,
                logout: logout,
                networkUserViewModel: networkUserViewModel,
                referralLinkViewModel: referralLinkViewModel,
                providerCountries: providerListStore.providerCountries,
                networkReliabilityWindow: networkReliabilityStore.reliabilityWindow,
                fetchNetworkReliability: networkReliabilityStore.getNetworkReliability,
                isPro: isPro
            )
            .background(themeManager.currentTheme.backgroundColor)
            .tabItem {
                VStack {
                    Image(selectedTab == 1 ? "ur.symbols.tab.account.fill" : "ur.symbols.tab.account")
                        .renderingMode(.template)
                                            
                    Text("Account")

                }
                .foregroundColor(themeManager.currentTheme.textColor)
            }
            .tag(1)
            
            /**
             * Leaderboard View
             */
            LeaderboardView(
                api: urApiService
            )
            .background(themeManager.currentTheme.backgroundColor)
            .tabItem {
                VStack {
                    
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    
                    Text("Leaderboard")
                        
                }
                .foregroundColor(themeManager.currentTheme.textColor)
            }
            .tag(2)
            
            /**
             * Feedback View
             */
            FeedbackView(
                urApiService: urApiService
            )
            .background(themeManager.currentTheme.backgroundColor)
            .tabItem {
                VStack {
                    Image(selectedTab == 3 ? "ur.symbols.tab.support.fill" : "ur.symbols.tab.support")
                        .renderingMode(.template)
                    
                    Text("Support")
                        
                }
                .foregroundColor(themeManager.currentTheme.textColor)
            }
            .tag(3)
                
        }
        .opacity(opacity)
        // a widget tap lands on the connect tab. The dashboard widget does
        // exactly what the Connect tab item does; the providers and contracts
        // widgets select the tab and the connect view takes their sheet from
        // there
        .onReceive(deepLinkRouter.$pending) { destination in
            guard let destination else { return }
            if destination == .connect {
                selectConnectTab()
            } else {
                selectedTab = 0
            }
        }
        // an onboarding email's link: the connect tab, Account > Widgets, the
        // offer on its own, or Support with the one-tap answer filled in
        .onReceive(deepLinkRouter.$pendingOnboarding) { destination in
            guard destination != nil, let destination = deepLinkRouter.consumeOnboarding() else { return }
            routeOnboarding(destination)
        }
        .sheet(isPresented: $presentOnboardingOffer) {
            OnboardingOfferSheet(dismiss: { presentOnboardingOffer = false })
                .environmentObject(themeManager)
        }
        .onAppear {
            setPresentationActive(presentationActive)
            withAnimation(.easeOut(duration: 1.0)) {
                opacity = 1
            }
        }
        .onChange(of: presentationActive) { active in
            setPresentationActive(active)
        }
        .onDisappear {
            setPresentationActive(false)
        }
        .fullScreenCover(isPresented: $displayIntroduction) {

            ZStack {

                IntroductionView(
                    close: {
                        // finished or skipped: persist it before the cover
                        // goes away, so a rebuilt tab view never re-prompts
                        IntroductionGate.finish(
                            introductionComplete: introductionComplete,
                            persist: deviceManager.completeIntroFunnel
                        )
                        displayIntroduction = false
                    },
                    totalReferrals: referralLinkViewModel.totalReferrals,
                    referralCode: referralLinkViewModel.referralCode ?? "",
                    meanReliabilityWeight: networkReliabilityStore.reliabilityWindow?.meanReliabilityWeight ?? 0,
                    api: urApiService,
                    referralTerms: referralLinkViewModel.terms
                )

                UrSnackBar(
                    message: snackbarManager.message,
                    isVisible: snackbarManager.isVisible
                )
                .padding(.bottom, 50)

            }
            .presentationBackgroundIfAvailable(themeManager.currentTheme.backgroundColor)

        }

        /**
         * Referral celebrations: the first referral gets the full-screen
         * crowning overlay; later ones get the gold snackbar. Detected by
         * the referral poll against the per-network celebrated baseline.
         */
        if let celebration = referralLinkViewModel.pendingCelebration, celebration.isFirst {
            ReferralCelebrationOverlay(
                joinedCount: celebration.joined,
                referralCode: referralLinkViewModel.referralCode,
                referralLinkViewModel: referralLinkViewModel,
                onDismiss: {
                    referralLinkViewModel.clearCelebration()
                }
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        }
        .animation(.easeInOut(duration: 0.3), value: referralLinkViewModel.pendingCelebration)
        .onChange(of: referralLinkViewModel.pendingCelebration) { celebration in
            guard let celebration = celebration, !celebration.isFirst else {
                return
            }
            snackbarManager.showSnackbar(
                message: String.localizedStringWithFormat(
                    String(localized: "%1$lld friends joined with your code! +%2$lld GiB/day each, for life."),
                    celebration.joined,
                    referralBonusGiBPerDay
                )
            )
            referralLinkViewModel.clearCelebration()
        }

    }

    private func routeOnboarding(_ destination: OnboardingDestination) {
        switch destination {
        case .connect:
            selectConnectTab()
        case .widgets:
            selectedTab = 1
            deepLinkRouter.pushAccount(.widgets)
        case .offer:
            if subscriptionBalanceViewModel.onboardingOffer != nil {
                presentOnboardingOffer = true
            } else {
                // no active offer: the regular upgrade sheet
                selectedTab = 0
                connectViewModel.isPresentedUpgradeSheet = true
            }
        case .feedback(let rating, let reason, let token):
            selectedTab = 3
            deepLinkRouter.prefillFeedback(FeedbackPrefill(rating: rating, reason: reason, token: token))
        }
    }

    /// What a tap on the Connect tab item does: select the tab, and when it
    /// is already selected, collapse the connect drawer. The tab item and the
    /// dashboard widget both go through here so the two cannot diverge.
    private func selectConnectTab() {
        if selectedTab == 0 {
            connectTabReselectCount += 1
        }
        selectedTab = 0
    }

    private func setPresentationActive(_ active: Bool) {
        referralLinkViewModel.setActive(active)
        networkReliabilityStore.setActive(active)
    }
    
    // used for adding a border above the tab bar
    private func setupTabBar() {
        let appearance = UITabBarAppearance()
        appearance.shadowColor = UIColor(white: 1.0, alpha: 0.12)
        // appearance.shadowImage = UIImage(named: "tab-shadow")?.withRenderingMode(.alwaysTemplate)
        // appearance.backgroundColor = UIColor(hex: "#101010")
        
        appearance.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        
        
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().standardAppearance = appearance
    
    }
    
}
#endif

//#Preview {
//    MainTabView(
//        api: SdkBringYourApi(), // TODO: need to mock this
//        device: SdkBringYourDevice(), // TODO: need to mock
//        logout: {}
//    )
//    .environmentObject(ThemeManager.shared)
//}
