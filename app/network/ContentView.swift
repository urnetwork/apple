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
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State var welcomeAnimationComplete: Bool = true
    
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
                                    
                                    if let vpnManager = deviceManager.vpnManager {
                                        await vpnManager.close()
                                    }
                                    
                                    deviceManager.logout()
                                }
                                
                            },
                            welcomeAnimationComplete: $welcomeAnimationComplete,
                            networkId: networkId
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
    
    private func updatePath() {
        
        withAnimation {
            opacity = 0.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            
            viewModel.updatePath(deviceManager.device)
            
            withAnimation {
                opacity = 1.0
            }
            
        }
    }
    
    private func handleSuccessWithJwt(_ jwt: String) async {
        
        welcomeAnimationComplete = false
     
        let result = await deviceManager.authenticateNetworkClient(jwt)
        
        if case .failure(let error) = result {
            print("[ContentView] handleSuccessWithJwt: \(error.localizedDescription)")
            
            snackbarManager.showSnackbar(message: "There was an error creating your network. Please try again later.")
            
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
