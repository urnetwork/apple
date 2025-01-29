//
//  MainTabView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

struct MainTabView: View {
    
    var api: SdkApi
    var device: SdkDeviceRemote
    var logout: () -> Void
    var connectViewController: SdkConnectViewController?
    @Binding var provideWhileDisconnected: Bool
    
    @State private var opacity: Double = 0
    @StateObject var providerListSheetViewModel: ProviderListSheetViewModel = ProviderListSheetViewModel()
    
    @StateObject var tunnelStateViewModel: TunnelStateViewModel
    
    var vpnManager: VPNManager
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var selectedTab = 0
    
    init(
        api: SdkApi,
        device: SdkDeviceRemote,
        vpnManager: VPNManager,
        logout: @escaping () -> Void,
        provideWhileDisconnected: Binding<Bool>
    ) {
        self.api = api
        self.logout = logout
        self.device = device
        self._provideWhileDisconnected = provideWhileDisconnected
        self.connectViewController = device.openConnectViewController()
        
        // vpn manager
//        self.vpnManager = VPNManager(device: device)
        self.vpnManager = vpnManager
        // vpnManager.loadOrCreateManager()
        
        _tunnelStateViewModel = StateObject(wrappedValue: TunnelStateViewModel(device: device))
        
        setupTabBar()
    }
    
    var body: some View {
        
        TabView(selection: $selectedTab) {
            
            /**
             * Connect View
             */
            ConnectView(
                api: api,
                logout: logout,
                device: device,
                connectViewController: connectViewController,
                providerListSheetViewModel: providerListSheetViewModel
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
                provideWhileDisconnected: $provideWhileDisconnected,
                logout: logout
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
             * Feedback View
             */
            FeedbackView(
                api: api
            )
            .background(themeManager.currentTheme.backgroundColor)
            .tabItem {
                VStack {
                    Image(selectedTab == 2 ? "ur.symbols.tab.support.fill" : "ur.symbols.tab.support")
                        .renderingMode(.template)
                    
                    Text("Support")
                        
                }
                .foregroundColor(themeManager.currentTheme.textColor)
            }
            .tag(2)
                
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

//#Preview {
//    MainTabView(
//        api: SdkBringYourApi(), // TODO: need to mock this
//        device: SdkBringYourDevice(), // TODO: need to mock
//        logout: {}
//    )
//    .environmentObject(ThemeManager.shared)
//}
