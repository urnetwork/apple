//
//  SettingsViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk
import UserNotifications
#if os(macOS)
import ServiceManagement
#endif

extension SettingsView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        let api: UrApiServiceProtocol
        
        @Published var presentUpdateReferralNetworkSheet: Bool = false
        
        @Published var version: String = ""
        
        init(api: UrApiServiceProtocol) {
            self.api = api
            
            #if os(macOS)
            self.launchAtStartupEnabled = SMAppService.mainApp.status == .enabled
            #endif
            
            checkNotificationSettings()
            
            Task {
                await fetchReferralNetwork()
            }
            
            self.version = SdkVersion
            
        }
        
        @Published var canReceiveNotifications: Bool = false {
            didSet {
                if canReceiveNotifications == true {
                    requestNotificationAuthorization()
                }
            }
        }
        
        /**
         * Delete account
         */
        @Published var isPresentedDeleteAccountConfirmation: Bool = false
        @Published var isDeletingNetwork: Bool = false
        
        #if os(macOS)
        @Published var launchAtStartupEnabled: Bool {
            didSet {
                // update here
                setLaunchAtStartup(launchAtStartupEnabled)
            }
        }
        #endif
        
        /**
         * Solana
         */
        @Published var presentSigninWithSolanaSheet: Bool = false
        @Published private(set) var isSigningMessage: Bool = false
        
        func setIsSigningMessage(_ isSigning: Bool) -> Void {
            isSigningMessage = isSigning
        }
        
        /**
         * Referral network
         */
        @Published private(set) var referralNetwork: SdkReferralNetwork? = nil
        
        let domain = "SettingsViewModel"
        
        private func checkNotificationSettings() {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined:
                    print("Notification permission not determined.")
                case .denied:
                    print("Notification permission denied.")
                case .authorized, .provisional, .ephemeral:
                    print("Notification permission granted.")
                    self.canReceiveNotifications = true
                @unknown default:
                    print("Unknown notification settings.")
                }
            }
        }
        
        private func requestNotificationAuthorization() {
            
            print("requestNotificationAuthorization hit")
            
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    // Handle the error here.
                    print("Error requesting authorization: \(error.localizedDescription)")
                }
                
                if !granted {
                    print("Notification authorization denied.")
                    DispatchQueue.main.async {
                        self.canReceiveNotifications = false
                    }
                }
            }
            
            
        }
        
        func deleteAccount() async -> Result<Void, Error> {
            
            if isDeletingNetwork {
                return .failure(NetworkDeleteError.inProgress)
            }
            
            self.isDeletingNetwork = true
                
            do {
                   
                let _ = try await api.deleteAccount()
                
                self.isDeletingNetwork = false
                
                return .success(())
                
            }
            catch(let error) {
                DispatchQueue.main.async {
                    self.isDeletingNetwork = false
                }
                return .failure(error)
            }
            
        }
        
        func fetchReferralNetwork() async {
            
            do {

                let result = try await api.getReferralNetwork()
                
                if result.error != nil {
                    print("fetch referral network result.error: \(String(describing: result.error?.message))")
                    self.referralNetwork = nil
                    return
                }

                self.referralNetwork = result.network

            } catch(let error) {
                print("\(domain) Error fetching transfer stats: \(error)")
                // isLoadingTransferStats = false
            }
            
        }
        
        #if os(macOS)
        private func setLaunchAtStartup(_ enabled: Bool) {
            print("setLaunchAtStartup hit with enabled value: \(enabled)")
            
            if (enabled == (SMAppService.mainApp.status == .enabled)) {
                print("caught, enabled value equals SMAppService.mainApp.status")
                return
            }
            
            do {
                if enabled {
                    print("enabling launch at system start")
                    try SMAppService.mainApp.register()
                } else {
                    print("disabling launch at system start")
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at startup: \(error)")
            }
        }
        #endif
        
    }
    
}
