//
//  MainNavigationSplitView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/08.
//

import SwiftUI
import URnetworkSdk

enum MainNavigationTab {
    case connect
    case account
    case leaderboard
    case support
}

#if os(macOS)
struct MainNavigationSplitView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectViewModel: ConnectViewModel
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @Environment(\.presentationActive) private var presentationActive

    @State private var selectedTab: MainNavigationTab = .connect
    @State private var displayIntroduction: Bool
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let device: SdkDeviceRemote
    let logout: () -> Void
    let isPro: Bool

    var iconWidth: CGFloat = 16
    
    // can probably pass this down from MainView
    @StateObject var providerListSheetViewModel: ProviderListSheetViewModel = ProviderListSheetViewModel()
    
    @StateObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @StateObject var networkUserViewModel: NetworkUserViewModel
    @StateObject var referralLinkViewModel: ReferralLinkViewModel
    
    @ObservedObject var providerListStore: ProviderListStore
    
    @StateObject private var networkReliabilityStore: NetworkReliabilityStore
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        providerListStore: ProviderListStore,
        introductionComplete: Binding<Bool>,
        isPro: Bool
    ) {
        self.api = api
        self.urApiService = urApiService
        self.logout = logout
        self.device = device
        self.providerListStore = providerListStore

        _accountPaymentsViewModel = StateObject.init(wrappedValue: AccountPaymentsViewModel(
                api: api
            )
        )
        
        _networkUserViewModel = StateObject(wrappedValue: NetworkUserViewModel(api: api))
        
        _referralLinkViewModel = StateObject(wrappedValue: ReferralLinkViewModel(api: api))
        
        _networkReliabilityStore = StateObject(wrappedValue: NetworkReliabilityStore(api: urApiService))
        
        self.isPro = isPro

        /**
         * Prompt introduction (mirrors iOS MainTabView gating)
         */
        if isPro {
            self.displayIntroduction = false
        } else if introductionComplete.wrappedValue {
            self.displayIntroduction = false
        } else {
            self.displayIntroduction = true
        }
    }
    
    var body: some View {

        ZStack {

        NavigationSplitView {
            List(selection: $selectedTab) {
                
                HStack {

                    Image(selectedTab == .connect ? "ur.symbols.tab.connect.fill" : "ur.symbols.tab.connect")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: iconWidth, height: iconWidth)

                    Text("Connect")
                    
                }
                .foregroundColor(themeManager.currentTheme.textColor)
                .tag(MainNavigationTab.connect)
                
                HStack {
                    
                    Image(selectedTab == .account ? "ur.symbols.tab.account.fill" : "ur.symbols.tab.account")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: iconWidth, height: iconWidth)
                                            
                    Text("Account")
                    
                }
                .foregroundColor(themeManager.currentTheme.textColor)
                .tag(MainNavigationTab.account)
                
                HStack {
                    
                    // Image(selectedTab == .leaderboard ? "ur.symbols.tab.account.fill" : "ur.symbols.tab.account")
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: iconWidth, height: iconWidth)
                        // .renderingMode(.template)
                                            
                    Text("Leaderboard")
                    
                }
                .foregroundColor(themeManager.currentTheme.textColor)
                .tag(MainNavigationTab.leaderboard)
                
                HStack {
                    
                    Image(selectedTab == .support ? "ur.symbols.tab.support.fill" : "ur.symbols.tab.support")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: iconWidth, height: iconWidth)
                    
                    Text("Support")
                    
                }
                .foregroundColor(themeManager.currentTheme.textColor)
                .tag(MainNavigationTab.support)

            }
        }
        detail: {
            
            switch selectedTab {
            case .connect:
                ConnectView_macOS(
                    urApiService: urApiService,
                    providerStore: providerListStore,
                    promptMoreDataFlow: { displayIntroduction = true },
                    meanReliabilityWeight: networkReliabilityStore.reliabilityWindow?.meanReliabilityWeight ?? 0,
                    totalReferrals: referralLinkViewModel.totalReferrals,
                    referralCode: referralLinkViewModel.referralCode,
                    isPro: isPro
                )
            case .account:
                AccountNavStackView(
                    api: api,
                    urApiService: urApiService,
                    device: device,
                    logout: logout,
                    accountPaymentsViewModel: accountPaymentsViewModel,
                    networkUserViewModel: networkUserViewModel,
                    referralLinkViewModel: referralLinkViewModel,
                    providerCountries: providerListStore.providerCountries,
                    networkReliabilityWindow: networkReliabilityStore.reliabilityWindow,
                    fetchNetworkReliability: networkReliabilityStore.getNetworkReliability,
                    isPro: isPro
                )
            case .leaderboard:
                LeaderboardView(api: urApiService)
            case .support:
                FeedbackView(
                    urApiService: urApiService
                )
                .background(themeManager.currentTheme.backgroundColor)
                .tabItem {
                    VStack {
                        Image(selectedTab == .support ? "ur.symbols.tab.support.fill" : "ur.symbols.tab.support")
                            .renderingMode(.template)
                        
                        Text("Support")
                            
                    }
                    .foregroundColor(themeManager.currentTheme.textColor)
                }
            }
        }
        .sheet(isPresented: $displayIntroduction) {
            IntroductionView(
                close: { displayIntroduction = false },
                totalReferrals: referralLinkViewModel.totalReferrals,
                referralCode: referralLinkViewModel.referralCode ?? "",
                meanReliabilityWeight: networkReliabilityStore.reliabilityWindow?.meanReliabilityWeight ?? 0,
                api: urApiService
            )
            .environmentObject(themeManager)
            .environmentObject(deviceManager)
            .environmentObject(subscriptionManager)
            .environmentObject(subscriptionBalanceViewModel)
            .environmentObject(connectViewModel)
            .frame(minWidth: 600, minHeight: 700)
        }
        .onAppear {
            setPresentationActive(presentationActive)
        }
        .onChange(of: presentationActive) { active in
            setPresentationActive(active)
        }
        .onDisappear {
            setPresentationActive(false)
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

    private func setPresentationActive(_ active: Bool) {
        referralLinkViewModel.setActive(active)
        networkReliabilityStore.setActive(active)
    }
}

//#Preview {
//    MainNavigationSplitView()
//}

#endif
