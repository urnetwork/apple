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
    
    @StateObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @StateObject var networkUserViewModel: NetworkUserViewModel
    @StateObject var referralLinkViewModel: ReferralLinkViewModel
    @StateObject private var networkReliabilityStore: NetworkReliabilityStore
    
    @ObservedObject var providerListStore: ProviderListStore
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @Environment(\.presentationActive) private var presentationActive
    
    @State private var selectedTab = 0
    @State private var displayIntroduction: Bool
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
        
        _accountPaymentsViewModel = StateObject.init(wrappedValue: AccountPaymentsViewModel(
                api: api
            )
        )
        
        _networkUserViewModel = StateObject(wrappedValue: NetworkUserViewModel(api: api))
        
        _referralLinkViewModel = StateObject(wrappedValue: ReferralLinkViewModel(api: api))
        
        _networkReliabilityStore = StateObject(wrappedValue: NetworkReliabilityStore(api: urApiService))
        
        self.introductionComplete = introductionComplete
        
        /**
         * Prompt introduction
         */
        if (isPro || errorFetchingSubscriptionBalance) {
            self.displayIntroduction = false
        } else {
            
            if introductionComplete.wrappedValue {
                self.displayIntroduction = false
            } else {
                self.displayIntroduction = true
            }
            
        }
        
        setupTabBar()
    }
    
    var body: some View {

        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == 0 && selectedTab == 0 {
                    // re-tapped the connect tab
                    connectTabReselectCount += 1
                }
                selectedTab = newValue
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
                accountPaymentsViewModel: accountPaymentsViewModel,
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
                        displayIntroduction = false
                    },
                    totalReferrals: referralLinkViewModel.totalReferrals,
                    referralCode: referralLinkViewModel.referralCode ?? "",
                    meanReliabilityWeight: networkReliabilityStore.reliabilityWindow?.meanReliabilityWeight ?? 0,
                    api: urApiService
                )
                
                UrSnackBar(
                    message: snackbarManager.message,
                    isVisible: snackbarManager.isVisible
                )
                .padding(.bottom, 50)
                
            }
            .presentationBackground(themeManager.currentTheme.backgroundColor)
            
        }
        
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
