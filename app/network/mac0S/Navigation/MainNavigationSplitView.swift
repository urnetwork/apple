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
    
    @State private var selectedTab: MainNavigationTab = .connect
    
    var api: SdkApi
    let urApiService: UrApiServiceProtocol
    var device: SdkDeviceRemote
    var logout: () -> Void
    
    var connectViewController: SdkConnectViewController?
    
    var iconWidth: CGFloat = 16
    
    // can probably pass this down from MainView
    @StateObject var providerListSheetViewModel: ProviderListSheetViewModel = ProviderListSheetViewModel()
    
    @StateObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @StateObject var networkUserViewModel: NetworkUserViewModel
    @StateObject var referralLinkViewModel: ReferralLinkViewModel
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void
    ) {
        self.api = api
        self.urApiService = urApiService
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
    }
    
    var body: some View {
        
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
                    api: api
                )
            case .account:
                AccountNavStackView(
                    api: api,
                    device: device,
                    logout: logout,
                    accountPaymentsViewModel: accountPaymentsViewModel,
                    networkUserViewModel: networkUserViewModel,
                    referralLinkViewModel: referralLinkViewModel
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
        
    }
}

//#Preview {
//    MainNavigationSplitView()
//}

#endif
