//
//  MainView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/07.
//

import SwiftUI
import URnetworkSdk

struct MainView: View {
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let device: SdkDeviceRemote
    var logout: () -> Void
    // var connectViewController: SdkConnectViewController?
    var welcomeAnimationComplete: Binding<Bool>
    @StateObject private var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @StateObject private var subscriptionManager: AppStoreSubscriptionManager
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    init(
        api: SdkApi,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        welcomeAnimationComplete: Binding<Bool>,
        networkId: SdkId?
    ) {
        self.api = api
        self.logout = logout
        self.device = device
        let urApiService = UrApiService(api: api)
        self.urApiService = urApiService
        self.welcomeAnimationComplete = welcomeAnimationComplete
        _subscriptionBalanceViewModel = StateObject(
            wrappedValue: SubscriptionBalanceViewModel(
                urApiService: urApiService
            )
        )
        _subscriptionManager = StateObject(wrappedValue: AppStoreSubscriptionManager(networkId: networkId))
    }
    
    var body: some View {
        
        Group {
         
            switch welcomeAnimationComplete.wrappedValue {
                case false:
                WelcomeAnimation(
                    welcomeAnimationComplete: self.welcomeAnimationComplete
                )
                case true:
                #if os(iOS)
                MainTabView(
                    api: api,
                    urApiService: urApiService,
                    device: device,
                    logout: self.logout
                )
                #elseif os(macOS)
                MainNavigationSplitView(
                    api: api,
                    urApiService: urApiService,
                    device: device,
                    logout: self.logout
                )
                #endif
            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .environmentObject(subscriptionBalanceViewModel)
        .environmentObject(subscriptionManager)
    }
}

struct WelcomeAnimation: View {
    
    @Binding var welcomeAnimationComplete: Bool
    @State private var opacity: Double = 1
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var globeSize: CGFloat = 256
    @State private var welcomeOffset: CGFloat = 400
    @State private var backgroundOpacity: Double = 0
    
    var body: some View {
        
        GeometryReader { geometry in
            
            let size = geometry.size
         
            ZStack {
                
                Image("OnboardingBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, minHeight: 0)
                    .ignoresSafeArea()
                    .opacity(backgroundOpacity)
                
                VStack(spacing: -2) {
                    
                    // top overlay
                    Rectangle()
                        .fill(.urBlack)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                    
                    
                    VStack(spacing: -2) {
                        
                        HStack(spacing: -2) {
                            // left overlay
                            Rectangle()
                                .fill(.urBlack)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                            // mask
                            Image("GlobeMask")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: globeSize + 2, height: globeSize + 2)
                                .offset(x: -1, y: -1)
                            
                            // right overlay
                            Rectangle()
                                .fill(.urBlack)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                    }
                    .frame(maxWidth: .infinity, maxHeight: globeSize)
                    
                    // bottom overlay
                    Rectangle()
                        .fill(.urBlack)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .bottom)
                    
                    
                }
                .position(x: size.width / 2, y: size.height / 2)

                // Welcome message overlay
                VStack {
                    
                    Spacer()
                 
                    VStack {
                        
                        HStack {
                            Image("ur.symbols.globe")
                            Spacer()
                        }
                        
                        HStack {
                            Text("Nicely done.")
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            
                            Spacer()
                        }
                        
                        HStack {
                            Text("Step into the internet as it should be.")
                                .font(themeManager.currentTheme.titleFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            
                            Spacer()
                        }
                        
                        UrButton(
                            text: "Enter",
                            action: {
                                handleExit()
                            },
                            style: .outlinePrimary
                        )
                        
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.urLightYellow)
                    .cornerRadius(12)
                    .padding()
                    
                }
                .frame(maxWidth: 400)
                .offset(y: welcomeOffset) // Apply the offset to move the VStack offscreen
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        withAnimation(.easeInOut) {
                            welcomeOffset = 0 // Slide the VStack up onscreen
                        }
                    }
                }
                
            }
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .opacity(opacity)
            .onAppear {
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeIn) {
                        backgroundOpacity = 1
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    expandMask(size: size)
                }
                
            }
            
        }
        
    }
    
    private func expandMask(size: CGSize) {
        let targetSize = max(size.width, size.height) * 1.5 // ensure the mask is larger than the screen
        withAnimation(.easeInOut(duration: 2.0)) {
            globeSize = targetSize
        }
    }
    
    private func handleExit() {
        

        withAnimation(.easeInOut) {
            welcomeOffset = 400
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 1.0)) {
                opacity = 0.0
            }
            
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            welcomeAnimationComplete = true
        }
        
    }
    
}

#Preview {
    
    let themeManager = ThemeManager.shared
    
    VStack {
        WelcomeAnimation(welcomeAnimationComplete: .constant(false))
    }
    .environmentObject(themeManager)
    .background(themeManager.currentTheme.backgroundColor)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

