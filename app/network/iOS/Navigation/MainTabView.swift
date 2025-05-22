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
    
    var api: SdkApi
    var device: SdkDeviceRemote
    var logout: () -> Void
    var connectViewController: SdkConnectViewController?
    
    @State private var opacity: Double = 0
    @StateObject var providerListSheetViewModel: ProviderListSheetViewModel = ProviderListSheetViewModel()
    
    @StateObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @StateObject var networkUserViewModel: NetworkUserViewModel
    @StateObject var referralLinkViewModel: ReferralLinkViewModel
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var selectedTab = 0
    
    init(
        api: SdkApi,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void
    ) {
        self.api = api
        self.logout = logout
        self.device = device
        
        // todo: investigate why we need this?
        // we're launching this in NetworkApp
        // but without it, disconnect isn't triggered
        self.connectViewController = device.openConnectViewController()
        
        _accountPaymentsViewModel = StateObject.init(wrappedValue: AccountPaymentsViewModel(
                api: api
            )
        )
        
        _networkUserViewModel = StateObject(wrappedValue: NetworkUserViewModel(api: api))
        
        _referralLinkViewModel = StateObject(wrappedValue: ReferralLinkViewModel(api: api))
        
        setupTabBar()
    }
    
    var body: some View {
        
        TabView(selection: $selectedTab) {
            
            /**
             * Connect View
             */
            ConnectView_iOS(
                api: api,
                logout: logout,
                device: device,
                providerListSheetViewModel: providerListSheetViewModel,
                referralLinkViewModel: referralLinkViewModel
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
                device: device,
                logout: logout,
                accountPaymentsViewModel: accountPaymentsViewModel,
                networkUserViewModel: networkUserViewModel,
                referralLinkViewModel: referralLinkViewModel
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
                api: api
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
                api: api
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
            withAnimation(.easeOut(duration: 1.0)) {
                opacity = 1
            }
        }
        
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
