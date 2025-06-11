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
        
        var api: SdkApi
        
        init(api: SdkApi) {
            self.api = api
            
            #if os(macOS)
            self.launchAtStartupEnabled = SMAppService.mainApp.status == .enabled
            #endif
            
            checkNotificationSettings()
            fetchReferralNetwork()
            
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
            
            DispatchQueue.main.async {
                self.isDeletingNetwork = true
            }
                
            do {
                
                let result: SdkNetworkDeleteResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                    guard let self = self else { return }
                    
                    let callback = NetworkDeleteCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: SendPasswordResetLinkError.resultInvalid)
                            return
                        }
                        
                        continuation.resume(returning: result)
                        
                    }
                    
                    api.networkDelete(callback)
                    
                }
                   
                DispatchQueue.main.async {
                    self.isDeletingNetwork = false
                }
                
                return .success(())
                
            }
            catch(let error) {
                DispatchQueue.main.async {
                    self.isDeletingNetwork = false
                }
                return .failure(error)
            }
            
        }
        
        func fetchReferralNetwork() {
            
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

private class NetworkDeleteCallback: SdkCallback<SdkNetworkDeleteResult, SdkNetworkDeleteCallbackProtocol>, SdkNetworkDeleteCallbackProtocol {
    func result(_ result: SdkNetworkDeleteResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetReferralNetworkCallback: SdkCallback<SdkGetReferralNetworkResult, SdkGetReferralNetworkResultCallbackProtocol>, SdkGetReferralNetworkResultCallbackProtocol {
    func result(_ result: SdkGetReferralNetworkResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum NetworkDeleteError: Error {
    case inProgress
    case resultInvalid
}
