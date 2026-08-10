//
//  ContentView.swift
//  network
//
//  Created by brien on 11/18/24.
//

import SwiftUI
import URnetworkSdk
import GoogleSignIn

struct ContentView: View {
    
    var api: SdkApi?
    
    @StateObject var viewModel = ViewModel()
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var connectViewModel: ConnectViewModel
    @StateObject private var snackbarManager = UrSnackbarManager()
    @StateObject private var connectWalletProviderViewModel = ConnectWalletProviderViewModel()
    
    @State private var opacity: Double = 0.0
    @State private var updatePathWorkItem: DispatchWorkItem?
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State var welcomeAnimationComplete: Bool = true
    @State var introductionComplete: Bool = true
    
    var body: some View {
        ZStack {
            
            if let api = deviceManager.api {
                
                switch viewModel.contentViewPath {
                    
                case .uninitialized:
                    ProgressView()
                case .authenticate:
                    LoginNavigationView(
                        api: api,
                        handleSuccess: handleSuccessWithJwt
                    )
                    .id(deviceManager.activeHostName)
                    .opacity(opacity)

                case .main:
                    if let device = deviceManager.device, let _ = deviceManager.vpnManager {
                        
                        let networkId = deviceManager.parsedJwt?.networkId
                        
                        MainView(
                            api: api,
                            device: device,
                            logout: {
                                
                                Task {
                                    connectViewModel.disconnect()
                                    deviceManager.logout()
                                }
                                
                            },
                            welcomeAnimationComplete: $welcomeAnimationComplete,
                            networkId: networkId,
                            introductionComplete: $introductionComplete,
                            isPro: deviceManager.isPro
                        )
                        .opacity(opacity)

                    } else {
                        ProgressView("Loading...")
                    }
                    
                }
                
            } else {
                ProgressView()
            }
            
            UrSnackBar(message: snackbarManager.message, isVisible: snackbarManager.isVisible)
                .padding(.bottom, 50)

            // Present only in acceptance builds.  XCUITest asserts this
            // compile-time marker before touching credentials, which prevents
            // a stale installed app from masquerading as the local build.
            if let acceptanceBuildID {
                Text(acceptanceBuildID)
                    .font(.system(size: 1))
                    .frame(width: 1, height: 1)
                    .clipped()
                    .opacity(0.01)
                    .accessibilityIdentifier("acceptance.build.id")
                Text(NetworkConfig.officialEnvName)
                    .font(.system(size: 1))
                    .frame(width: 1, height: 1)
                    .clipped()
                    .opacity(0.01)
                    .accessibilityIdentifier("acceptance.environment")
                if let networkID = deviceManager.parsedJwt?.networkId?.idStr {
                    Text(networkID)
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .clipped()
                        .opacity(0.01)
                        .accessibilityIdentifier("acceptance.network.id")
                }
                if let clientID = deviceManager.device?.getClientId()?.idStr {
                    Text(clientID)
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .clipped()
                        .opacity(0.01)
                        .accessibilityIdentifier("acceptance.client.id")
                }
            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(deviceManager)
        .background(themeManager.currentTheme.backgroundColor)
        .environmentObject(snackbarManager)
        .environmentObject(connectWalletProviderViewModel)
        .onReceive(deviceManager.$device) { device in
  
            updatePath()
            
        }
        
    }

    private var acceptanceBuildID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "URAcceptanceBuildID") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return nil
        }
        return value
    }
    
    private func updatePath() {
        updatePathWorkItem?.cancel()

        withAnimation {
            opacity = 0.0
        }

        let workItem = DispatchWorkItem {
            viewModel.updatePath(deviceManager.device)
            withAnimation {
                opacity = 1.0
            }
        }
        updatePathWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func handleSuccessWithJwt(_ jwt: String) async {
        
        self.welcomeAnimationComplete = false
        self.introductionComplete = false
     
        let result = await deviceManager.authenticateNetworkClient(jwt)
        
        if case .failure(let error) = result {
            print("[ContentView] handleSuccessWithJwt: \(error.localizedDescription)")
            
            snackbarManager.showSnackbar(message: String(localized: "There was an error creating your network. Please try again later."))
            
            return
        }
        
    }
    
}
//
//#Preview {
//    ContentView(
//        api: SdkBringYourApi()
//    )
//        .environmentObject(ThemeManager.shared)
//}
