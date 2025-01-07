//
//  MainView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/07.
//

import SwiftUI
import URnetworkSdk

struct MainView: View {
    
    var api: SdkBringYourApi
    var device: SdkBringYourDevice
    var logout: () -> Void
    var connectViewController: SdkConnectViewController?
    
    // var vpnManager: VPNManager
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    // @State private var selectedTab = 0
    
    @State private var welcomeAnimationComplete = false
    
    
    
    init(
        api: SdkBringYourApi,
        device: SdkBringYourDevice,
        logout: @escaping () -> Void
    ) {
        self.api = api
        self.logout = logout
        self.device = device
        self.connectViewController = device.openConnectViewController()
        
        // vpn manager
        // self.vpnManager = VPNManager(device: device)
        // vpnManager.loadOrCreateManager()
    }
    
    var body: some View {
        
        Group {
         
            switch welcomeAnimationComplete {
                case false:
                WelcomeAnimation(
                    welcomeAnimationComplete: $welcomeAnimationComplete
                )
                case true:
                MainTabView(
                    api: api,
                    device: device,
                    logout: deviceManager.logout,
                    provideWhileDisconnected: $deviceManager.provideWhileDisconnected
                )
            }
            
        }
    }
}

struct WelcomeAnimation: View {
    
    @Binding var welcomeAnimationComplete: Bool
    @State private var opacity: Double = 1
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var globeSize: CGFloat = 256
    @State private var welcomeOffset: CGFloat = 400
    
    var body: some View {
        
        GeometryReader { geometry in
            
            let size = geometry.size
         
            ZStack {
                
                Image("OnboardingBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0)
                    .ignoresSafeArea()
                
                VStack {
                    
                    VStack {
                        Spacer()
                        
                        HStack(spacing: 0) {
                            // Left overlay
                            Rectangle()
                                .fill(.urBlack)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                            Image("GlobeMask")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: globeSize, height: globeSize)
                            
                            // Right overlay
                            Rectangle()
                                .fill(.urBlack)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        Spacer()
                    }
                    .position(x: size.width / 2, y: size.height / 2)
                    
                    
                }
                
                // top overlay
                Rectangle()
                    .fill(.urBlack)
                    .frame(height: (size.height - globeSize) / 2 + geometry.safeAreaInsets.top)
                    .position(
                        x: size.width / 2,
                        y: ((size.height - globeSize) / 4) + (geometry.safeAreaInsets.top / 2))
                    .ignoresSafeArea(edges: .top)
                
                // bottom overlay
                Rectangle()
                    .fill(.urBlack)
                    .frame(height: (size.height - globeSize) / 2 + geometry.safeAreaInsets.bottom)
                    .position(
                        x: size.width / 2,
                        y: size.height - ((size.height - globeSize) / 4) - (geometry.safeAreaInsets.bottom / 2) + geometry.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
            
                
                
                
                
//                Image("GlobeMask")
//                    .resizable()
//                    .aspectRatio(contentMode: .fit)
//                    .frame(width: globeSize, height: globeSize)
//                    .position(x: size.width / 2, y: size.height / 2)
//
//                // top overlay
//                Rectangle()
//                    .fill(.urBlack)
//                    .frame(height: (size.height - globeSize) / 2 + geometry.safeAreaInsets.top)
//                    .position(
//                        x: size.width / 2,
//                        y: ((size.height - globeSize) / 4) + (geometry.safeAreaInsets.top / 2))
//                    .ignoresSafeArea(edges: .top)
//
//                // bottom overlay
//                Rectangle()
//                    .fill(.urBlack)
//                    .frame(height: (size.height - globeSize) / 2 + geometry.safeAreaInsets.bottom)
//                    .position(
//                        x: size.width / 2,
//                        y: size.height - ((size.height - globeSize) / 4) - (geometry.safeAreaInsets.bottom / 2) + geometry.safeAreaInsets.bottom)
//                    .ignoresSafeArea(edges: .bottom)
//
//
//                // Left overlay
//                Rectangle()
//                    .fill(.urBlack)
//                    .frame(
//                        width: (size.width - globeSize) / 2
//                    )
//                    .position(
//                        // x: (size.width - globeSize) / 4,
//                        x: 0,
//                        y: size.height / 2
//                    )
//
//                // Right overlay
//                Rectangle()
//                    .fill(.urBlack)
//                    .frame(width: (size.width - globeSize) / 2)
//                    .position(x: size.width - (size.width - globeSize) / 4, y: size.height / 2)
                
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
                .offset(y: welcomeOffset) // Apply the offset to move the VStack offscreen
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        withAnimation(.easeInOut(duration: 1.0)) {
                            welcomeOffset = 0 // Slide the VStack up onscreen
                        }
                    }
                }
                
            }
            .opacity(opacity)
            .onAppear {
                
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
        
        withAnimation(.easeOut(duration: 1.0)) {
            opacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            welcomeAnimationComplete = true
        }
        
        // welcomeAnimationComplete = true
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

//#Preview {
//    MainView()
//}
