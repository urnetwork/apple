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
        
        var networkUserViewModel: NetworkUserViewModel?
        
        init(api: UrApiServiceProtocol, networkUserViewModel: NetworkUserViewModel? = nil) {
            self.api = api
            self.networkUserViewModel = networkUserViewModel
            
            #if os(macOS)
            self.launchAtStartupEnabled = SMAppService.mainApp.status == .enabled
            #endif
            
            checkNotificationSettings()
            
            Task {
                await fetchReferralNetwork()
            }
            
            self.version = SdkVersion
            
        }
        
        private var isCheckingNotificationSettings = true

        @Published var canReceiveNotifications: Bool = false {
            didSet {
                guard !isCheckingNotificationSettings, canReceiveNotifications == true else { return }
                requestNotificationAuthorization()
            }
        }
        
        /**
         * Delete account
         */
        @Published var isPresentedDeleteAccountConfirmation: Bool = false
        @Published var isDeletingNetwork: Bool = false
        
        #if os(macOS)
        private var isApplyingLaunchAtStartupState = false

        @Published var launchAtStartupEnabled: Bool {
            didSet {
                guard !isApplyingLaunchAtStartupState else { return }
                guard oldValue != launchAtStartupEnabled else { return }
                setLaunchAtStartup(launchAtStartupEnabled, previousValue: oldValue)
            }
        }
        #endif
        
        /**
         * Referral network
         */
        @Published private(set) var referralNetwork: SdkReferralNetwork? = nil

        /**
         * Device
         */
        @Published private(set) var deviceId: SdkId? = nil
        @Published private(set) var deviceName: String = ""
        @Published private(set) var deviceSpec: String = ""
        @Published var isPresentedRenameDevice: Bool = false
        @Published var editingDeviceName: String = ""
        @Published private(set) var isUpdatingDeviceName: Bool = false

        let domain = "SettingsViewModel"

        func fetchDeviceInfo(_ clientId: SdkId?) async {

            guard let clientId = clientId else {
                return
            }

            do {
                let result = try await api.getNetworkClients()

                guard let clients = result.clients else {
                    return
                }

                for i in 0..<clients.len() {
                    guard let info = clients.get(i) else {
                        continue
                    }
                    if info.clientId?.idStr == clientId.idStr {
                        self.deviceId = info.deviceId
                        self.deviceName = !info.deviceName.isEmpty ? info.deviceName : info.deviceDescription
                        self.deviceSpec = info.deviceSpec
                        break
                    }
                }
            } catch(let error) {
                print("[\(domain)] Error fetching device info: \(error)")
            }

        }

        func presentRenameDevice() {
            editingDeviceName = deviceName
            isPresentedRenameDevice = true
        }

        func updateDeviceName() async -> Result<Void, Error> {

            guard let deviceId = deviceId else {
                return .failure(DeviceInfoError.resultEmpty)
            }

            let name = editingDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .failure(DeviceInfoError.resultEmpty)
            }

            isUpdatingDeviceName = true

            do {
                try await api.deviceSetName(deviceId: deviceId, deviceName: name)
                self.deviceName = name
                isUpdatingDeviceName = false
                return .success(())
            } catch(let error) {
                isUpdatingDeviceName = false
                return .failure(error)
            }

        }
        
        private func checkNotificationSettings() {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined:
                    Task { @MainActor in
                        self.isCheckingNotificationSettings = false
                    }
                case .denied:
                    Task { @MainActor in
                        self.isCheckingNotificationSettings = false
                    }
                case .authorized, .provisional, .ephemeral:
                    Task { @MainActor in
                        self.canReceiveNotifications = true
                        self.isCheckingNotificationSettings = false
                    }
                    
                @unknown default:
                    print("Unknown notification settings.")
                    Task { @MainActor in
                        self.isCheckingNotificationSettings = false
                    }
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
                self.isDeletingNetwork = false
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
            }
            
        }
        
        #if os(macOS)
        private func setLaunchAtStartup(_ enabled: Bool, previousValue: Bool) {
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
                isApplyingLaunchAtStartupState = true
                launchAtStartupEnabled = previousValue
                isApplyingLaunchAtStartupState = false
            }
        }
        #endif
        
        // MARK: - Seedphrase Management
        
        @Published var presentSeedphraseSheet: Bool = false
        @Published var generatedSeedphrase: String = ""
        @Published var isGeneratingSeedphrase: Bool = false
        @Published var isRegeneratingSeedphrase: Bool = false
        @Published var presentSeedphraseConfirmation: Bool = false
        @Published var seedphraseError: String?
        
        private var pendingSeedphraseAction: SeedphraseAction = .generate
        
        enum SeedphraseAction {
            case generate
            case regenerate
        }
        
        func confirmGenerateSeedphrase() {
            pendingSeedphraseAction = .generate
            presentSeedphraseConfirmation = true
        }
        
        func confirmRegenerateSeedphrase() {
            pendingSeedphraseAction = .regenerate
            presentSeedphraseConfirmation = true
        }
        
        func executePendingSeedphraseAction() async {
            switch pendingSeedphraseAction {
            case .generate:
                await executeGenerateSeedphrase()
            case .regenerate:
                await executeRegenerateSeedphrase()
            }
        }
        
        func executeGenerateSeedphrase() async {
            isGeneratingSeedphrase = true
            seedphraseError = nil
            
            do {
                let result = try await api.generateSeedphrase()
                self.generatedSeedphrase = result.seedphrase
                self.isGeneratingSeedphrase = false
                self.presentSeedphraseConfirmation = false
                self.presentSeedphraseSheet = true
                // Refresh user data to get updated auth_types
                Task { [weak self] in
                    _ = await self?.networkUserViewModel?.refreshNetworkUser()
                }
            } catch(let error) {
                self.isGeneratingSeedphrase = false
                self.presentSeedphraseConfirmation = false
                self.seedphraseError = error.localizedDescription
            }
        }
        
        func executeRegenerateSeedphrase() async {
            isRegeneratingSeedphrase = true
            seedphraseError = nil
            
            do {
                let result = try await api.regenerateSeedphrase()
                self.generatedSeedphrase = result.seedphrase
                self.isRegeneratingSeedphrase = false
                self.presentSeedphraseConfirmation = false
                self.presentSeedphraseSheet = true
                // Refresh user data to get updated auth_types
                Task { [weak self] in
                    _ = await self?.networkUserViewModel?.refreshNetworkUser()
                }
            } catch(let error) {
                self.isRegeneratingSeedphrase = false
                self.presentSeedphraseConfirmation = false
                self.seedphraseError = error.localizedDescription
            }
        }
        
        func dismissSeedphraseSheet() {
            self.presentSeedphraseSheet = false
            self.generatedSeedphrase = ""
        }
        
        // MARK: - Auth Method Management
        
        @Published var presentAddAuthSheet: Bool = false
        @Published var presentRemoveAuthConfirmation: Bool = false
        @Published var authTypeToRemove: String?
        @Published var isAddingAuth: Bool = false
        @Published var isRemovingAuth: Bool = false
        @Published var addAuthError: String?
        @Published var removeAuthError: String?
        
        func presentRemoveAuth(_ authType: String) {
            self.authTypeToRemove = authType
            self.presentRemoveAuthConfirmation = true
        }
        
        func executeRemoveAuth() async {
            guard let authType = authTypeToRemove else { return }
            isRemovingAuth = true
            removeAuthError = nil
            
            do {
                let _ = try await api.removeAuth(authType: authType)
                self.isRemovingAuth = false
                self.presentRemoveAuthConfirmation = false
                self.authTypeToRemove = nil
                // Refresh user data to get updated auth_types
                Task { [weak self] in
                    _ = await self?.networkUserViewModel?.refreshNetworkUser()
                }
            } catch(let error) {
                self.isRemovingAuth = false
                self.removeAuthError = error.localizedDescription
            }
        }
        
    }
    
}
