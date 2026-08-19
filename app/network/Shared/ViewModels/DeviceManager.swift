//
//  GlobalStore.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/01.
//

import Foundation
import URnetworkSdk
import Combine
import Network

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct PerformanceProfilePropagationPlan {
    let persist: Bool
    let applyLive: Bool

    init(hasLiveDevice: Bool) {
        // Persistence owns user intent and is independent of the short-lived
        // DeviceRemote presentation lifecycle.
        persist = true
        applyLive = hasLiveDevice
    }
}

struct DeviceSettingWritePolicy {
    static func shouldPropagate(isLoadingFromDevice: Bool) -> Bool {
        !isLoadingFromDevice
    }
}

@MainActor
class DeviceManager: ObservableObject {
    
    let domain = "GlobalStore"
    
    @Published private(set) var networkSpace: SdkNetworkSpace? {
        didSet {
//            setApi(networkSpace?.getApi())
            // updateParsedJwt()
        }
    }

    @Published private(set) var networkSpaceManager: SdkNetworkSpaceManager?
    
    var api: SdkApi? {
        get {
            return self.networkSpace?.getApi()
        }
    }
    
    @Published private(set) var device: SdkDeviceRemote? = nil {
        didSet {
            setupDeviceListeners()
            updateParsedJwt()
            
            if let device = self.device {
                self.providePaused = device.getProvidePaused()
                self.provideEnabled = device.getProvideEnabled()
            }
        }
    }
    
    @Published private(set) var vpnManager: VPNManager? = nil
    private var isLoggingOut = false

    func applicationDidBecomeActive() {
        vpnManager?.applicationDidBecomeActive()
    }
    
    
    @Published var provideControlMode: ProvideControlMode = ProvideControlMode.Never {
        didSet {
            guard DeviceSettingWritePolicy.shouldPropagate(
                isLoadingFromDevice: isLoadingFromDevice
            ) else { return }
            handleProvideControlModeUpdate(provideControlMode)
        }
    }
    
    @Published var routeLocal: Bool = true {
        didSet {
            setRouteLocalInternal(routeLocal)
        }
    }

    private func setRouteLocalInternal(_ value: Bool) {
        do {
            try asyncLocalState?.getLocalState()?.setRouteLocal(value)
        } catch {
            print("error setting route local: \(error)")
        }

        device?.setRouteLocal(value)
    }

    @Published var blockerEnabled: Bool = false {
        didSet {
            guard !isLoadingFromDevice else { return }
            setBlockerEnabledInternal(blockerEnabled)
        }
    }

    // the extension device persists the toggle to local settings and restores
    // it at creation; the app-side local state mirror (shared storage) keeps
    // the toggle seeded when the extension device is not reachable
    private func setBlockerEnabledInternal(_ value: Bool) {
        do {
            try asyncLocalState?.getLocalState()?.setBlockerEnabled(value)
        } catch {
            print("error setting blocker enabled: \(error)")
        }

        device?.setBlockerEnabled(value)
    }
    
    @Published var allowProvidingCell: Bool = false {
        didSet {
            guard DeviceSettingWritePolicy.shouldPropagate(
                isLoadingFromDevice: isLoadingFromDevice
            ) else { return }
            updateAllowProvidingCell(allowProvidingCell)
        }
    }
    
    @Published private(set) var provideEnabled: Bool = false
    @Published private(set) var providePaused: Bool = false

    // the LIVE effective provide mode from the device (Public / FriendsAndFamily /
    // Network / None). Network provide is always kept active, so `provideEnabled`
    // (= the provider exists) no longer distinguishes public providing — this does.
    // ProvideMode is a bit set: compare per-case, never with ranges.
    @Published private(set) var currentProvideMode: Int = SdkProvideModeNone

    // true when the device is currently providing to the PUBLIC network — the
    // signal for the provide-settings indicator light
    var providingPublicly: Bool {
        currentProvideMode == SdkProvideModePublic
    }

    // whether the provider currently holds a Network-mode provide key — i.e. this
    // device is providing to same-network peers.
    @Published private(set) var providerHasNetworkKey: Bool = false
    // this device's editable network name (what peers see), from the network client
    // record. Empty until loaded.
    @Published private(set) var deviceName: String = ""

    // true when the device is providing to same-network peers and can accept a peer
    // connection — drives the connect screen's "discoverable as {name}" line.
    // Provide paused deliberately does NOT gate this: pause stops public provide
    // but keeps the Network mode announced and verifiable, so a paused device is
    // still connectable by its network peers.
    var providerDiscoverable: Bool {
        provideEnabled && providerHasNetworkKey
    }

    private var providerNetworkKeySub: SdkSubProtocol?

    private var isLoadingFromDevice = false

    private func withDeviceStateLoad(_ load: () -> Void) {
        let wasLoadingFromDevice = isLoadingFromDevice
        isLoadingFromDevice = true
        load()
        isLoadingFromDevice = wasLoadingFromDevice
    }
    
    @Published var selectedWindowType: WindowType = .auto {
        didSet {
            guard !isLoadingFromDevice else { return }
            
            if selectedWindowType == .auto && fixedIpSize != false {
                self.fixedIpSize = false
                // this will trigger createPerformanceProfile
                return
            }
            
            propagatePerformanceProfileToDevice()
        }
    }

    @Published var fixedIpSize: Bool = false {
        didSet {
            guard !isLoadingFromDevice else { return }
            propagatePerformanceProfileToDevice()
        }
    }
    
    @Published var allowDirect: Bool = false {
        didSet {
            guard !isLoadingFromDevice else { return }
            propagatePerformanceProfileToDevice()
        }
    }

    @Published var postQuantumEncryption: Bool = false {
        didSet {
            guard !isLoadingFromDevice else { return }
            propagatePerformanceProfileToDevice()
        }
    }

    private func createPerformanceProfile(
        windowType: WindowType,
        isFixedSize: Bool,
        allowDirect: Bool,
        postQuantumEncryption: Bool
    ) -> SdkPerformanceProfile {
        // always a profile, even for window type auto, so the orthogonal
        // settings (allow direct, post quantum encryption) persist and apply
        // in every mode
        let performanceProfile = SdkPerformanceProfile()
        performanceProfile.allowDirect = allowDirect
        performanceProfile.postQuantumEncryption = postQuantumEncryption

        switch windowType {
        case .auto:
            // no fixed window type or size
            performanceProfile.windowType = SdkWindowTypeAuto
        case .quality, .speed:
            performanceProfile.windowType = windowType == .quality ? SdkWindowTypeQuality : SdkWindowTypeSpeed

            let windowSizeSettings = SdkWindowSizeSettings()
            windowSizeSettings.windowSizeMin = isFixedSize ? 1 : 2
            windowSizeSettings.windowSizeMax = isFixedSize ? 1 : 4

            performanceProfile.windowSize = windowSizeSettings
        }

        return performanceProfile
    }
    
    /// Propagates UI state to device and storage (one direction only)
    private func propagatePerformanceProfileToDevice() {
        let profile = createPerformanceProfile(
            windowType: selectedWindowType,
            isFixedSize: fixedIpSize,
            allowDirect: allowDirect,
            postQuantumEncryption: postQuantumEncryption,
        )
        let plan = PerformanceProfilePropagationPlan(hasLiveDevice: device != nil)
        
        // Save to storage
        if plan.persist {
            do {
                try asyncLocalState?.getLocalState()?.setPerformanceProfile(profile)
            } catch {
                print("error updating performance profile: \(error)")
            }
        }
        
        // Update the live device when available. Persistence is intentionally
        // independent: a user choice made while the app is recreating its
        // DeviceRemote must not be discarded just because that short-lived
        // presentation gap has no device yet.
        if plan.applyLive {
            device?.setPerformanceProfile(profile)
        }
    }
    
    /// Loads performance profile from device into UI (called only during init)
    private func loadPerformanceProfileFromDevice(_ device: SdkDeviceRemote) {
        // Set flag to prevent didSet from triggering propagation
        let wasLoadingFromDevice = isLoadingFromDevice
        isLoadingFromDevice = true
        defer { isLoadingFromDevice = wasLoadingFromDevice }
        
        let performanceProfile = device.getPerformanceProfile()

        // a nil profile and window type auto mean the same thing
        if performanceProfile?.windowType == SdkWindowTypeQuality {
            self.selectedWindowType = .quality
        } else if performanceProfile?.windowType == SdkWindowTypeSpeed {
            self.selectedWindowType = .speed
        } else {
            self.selectedWindowType = .auto
        }

        self.allowDirect = performanceProfile?.allowDirect ?? false
        self.postQuantumEncryption = performanceProfile?.postQuantumEncryption ?? false

        if performanceProfile?.windowSize?.windowSizeMin == 1 && performanceProfile?.windowSize?.windowSizeMax == 1 {
            self.fixedIpSize = true
        } else {
            self.fixedIpSize = false
        }
    }
    
    @Published private(set) var isPro: Bool = false
    private func setIsPro(_ value: Bool) {
        self.isPro = value
    }
    
    private var deviceProvideSub: SdkSubProtocol?
    private var deviceProvidePausedSub: SdkSubProtocol?
    private var deviceJwtRefreshSub: SdkSubProtocol?
    private var deviceAuthLogoutSub: SdkSubProtocol?
    private var deviceCanShowRatingDialogSub: SdkSubProtocol?
    private var deviceCanPromptIntroFunnelSub: SdkSubProtocol?
    private var deviceAllowForegroundSub: SdkSubProtocol?
    private var deviceCanReferSub: SdkSubProtocol?
    private var deviceProvideModeSub: SdkSubProtocol?
    private var deviceProvideNetworkModeSub: SdkSubProtocol?
    private var deviceVpnInterfaceWhileOfflineSub: SdkSubProtocol?
    private var deviceDefaultLocationSub: SdkSubProtocol?
    private var deviceBlockerEnabledSub: SdkSubProtocol?

    private func updateAllowProvidingCell(_ allow: Bool) {
        #if os(iOS)
        let mode = allow ? SdkProvideNetworkModeAll : SdkProvideNetworkModeWiFi
        
        do {
            try asyncLocalState?.getLocalState()?.setProvideNetworkMode(mode)
        } catch {
            print("error setting route local: \(error)")
        }
        
        device?.setProvideNetworkMode(mode)
        #endif
    }
    
    func setDevice(device: SdkDeviceRemote?) {
        
        if self.device != device {
            
            cleanupDeviceListeners()
            self.vpnManager?.close()
            self.vpnManager = nil
            
            self.device?.close()
            self.device = device
            
            if let device = device {
                print("set device hit: device exists: resetting vpn manager")

                withDeviceStateLoad {
                    if let provideControlMode = ProvideControlMode(rawValue: device.getProvideControlMode()) {
                        self.provideControlMode = provideControlMode
                    }

                    if let provideNetworkMode = ProvideNetworkMode(rawValue: device.getProvideNetworkMode()) {
                        self.allowProvidingCell = provideNetworkMode == .All
                    }
                }

                loadPerformanceProfileFromDevice(device)
                
                self.deviceInitialized = true
                self.vpnManager = VPNManager(device: device)
            } else {
                withDeviceStateLoad {
                    self.provideControlMode = ProvideControlMode.Never
                    self.allowProvidingCell = false
                }
                self.deviceInitialized = false
            }
            
        }
    }
    
    func clearDevice() {
        setDevice(device: nil)
    }
    
    @Published private(set) var deviceInitialized: Bool = false
    
    private func handleProvideControlModeUpdate(_ mode: ProvideControlMode) {
        device?.setProvideControlMode(mode.rawValue)
        
        if let localState = asyncLocalState?.getLocalState() {
            
            do {
                try localState.setProvideControlMode(mode.rawValue)
            } catch(let error) {
                print("[\(domain)] Error setting provide control mode: \(error)")
            }
            
        } else {
            print("[\(domain)] No local state found when updating provide control mode")
        }
        
    }
    
    
    // The initial device name defaults to the human device name — never
    // "New device". On iOS/iPadOS it is the retail model name ("iPhone 16 Pro
    // Max"); on macOS it is the user's computer name ("Brien's MacBook Pro",
    // the System Settings > General > About > Name), falling back to the model.
    // Users can still rename their device (a separate, server-side
    // device_name); this is only the default a brand-new device registers with.
    var deviceDescription: String {
        #if os(macOS)
        let computerName = Host.current().localizedName
        if let computerName, !computerName.isEmpty {
            return computerName
        }
        return Self.deviceModelName()
        #else
        return Self.deviceModelName()
        #endif
    }

    // the retail model name (e.g. "iPhone 16 Pro Max", "MacBook Pro (16-inch,
    // Nov 2023)") resolved from the hardware identifier via the bundled
    // `DeviceModelNames` catalog; unknown/newer identifiers fall back to the
    // raw identifier, which still names the device.
    static func deviceModelName() -> String {
        let identifier = hardwareModelIdentifier()
        return DeviceModelNames.name(forIdentifier: identifier) ?? identifier
    }
    
    init() {
        
        Task {
            await self.initializeNetworkSpace()
        }
        
    }
    
    /**
     * used in app intents
     */
    func waitForDeviceInitialization() async {
        do {
            try await waitUntilDeviceInitialized()
        } catch {
            print("[\(domain)] Timed out waiting for device initialization: \(error)")
        }
    }
    
    var asyncLocalState: SdkAsyncLocalState? {
        return networkSpace?.getAsyncLocalState()
    }
    
    @Published private(set) var parsedJwt: SdkByJwt?
    
    private func updateParsedJwt() {
        guard let localState = networkSpace?.getAsyncLocalState()?.getLocalState() else {
            parsedJwt = nil
            return
        }
        
        do {
            parsedJwt = try localState.parseByJwt()
            setIsPro(parsedJwt?.pro ?? false)
        } catch {
            parsedJwt = nil
        }
    }
    
    func setCanShowRatingDialog(_ value: Bool) {
        do {
            try asyncLocalState?.getLocalState()?.setCanShowRatingDialog(value)
        } catch {
            print("error setting can show rating dialog: \(error)")
        }

        device?.setCanShowRatingDialog(value)
    }
    
    func setCanRefer(_ value: Bool) {
        do {
            try asyncLocalState?.getLocalState()?.setCanRefer(value)
        } catch {
            print("error setting can refer: \(error)")
        }
        
        device?.setCanRefer(value)
    }
    
    func setProvideControlMode(_ value: ProvideControlMode) {
        do {
            try asyncLocalState?.getLocalState()?.setProvideControlMode(value.rawValue)
        } catch {
            print("error setting provide while disconnected: \(error)")
        }
        
        device?.setProvideControlMode(value.rawValue)
    }
    
    func setVpnInterfaceWhileOffline(_ value: Bool) {
        do {
            try asyncLocalState?.getLocalState()?.setVpnInterfaceWhileOffline(value)
        } catch {
            print("error setting vpn interface while offline: \(error)")
        }
        
        device?.setVpnInterfaceWhileOffline(value)
    }
    
    func uploadLogs(feedbackId: String) throws {
        try device?.uploadLogs(feedbackId, callback: nil)
    }
    
    
    func closeOnQuit(completion: @escaping (Error?) -> Void) {
        self.device?.close()
        
        if let vpnManager = self.vpnManager {
            vpnManager.stopVpnTunnelOnQuit(completion: completion)
        } else {
            completion(nil)
        }
    }
    
}

private class NetworkSpaceUpdateCallback: NSObject, URnetworkSdk.SdkNetworkSpaceUpdateProtocol {
    var c: (URnetworkSdk.SdkNetworkSpaceValues) -> Void

    init(c: @escaping (URnetworkSdk.SdkNetworkSpaceValues) -> Void) {
        self.c = c
    }

    func update(_ values: URnetworkSdk.SdkNetworkSpaceValues?) {
        if let values {
            c(values)
        }
    }
}

private class GetJwtInitDeviceCallback: NSObject, SdkGetByClientJwtCallbackProtocol {
    
    weak var globalStore: DeviceManager?
    var deviceSpecs: String
    
    var onResult: (_ result: String?, _ ok: Bool) -> Void
    
    init(networkStore: DeviceManager?, deviceSpecs: String, onResult: @escaping (_ result: String?, _ ok: Bool) -> Void) {
        self.globalStore = networkStore
        self.deviceSpecs = deviceSpecs
        self.onResult = onResult
    }
    
    func result(_ result: String?, ok: Bool) {
        DispatchQueue.main.async {
            self.onResult(result, ok)
        }

    }
}

// MARK: Device initialized utils
extension DeviceManager {
    func waitUntilDeviceInitialized(timeout: TimeInterval = 30) async throws {
        if deviceInitialized { return }

        try await withTimeout(timeout) {
            for await initialized in self.$deviceInitialized.values {
                if initialized {
                    return
                }
            }
        }
    }
    
    func waitUntilDeviceUninitialized(timeout: TimeInterval = 30) async throws {
        if !deviceInitialized { return }

        try await withTimeout(timeout) {
            for await initialized in self.$deviceInitialized.values {
                if !initialized {
                    return
                }
            }
        }
    }
    
    private func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * Double(NSEC_PER_SEC)))
                throw DeviceManagerError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    enum DeviceManagerError: Error {
        case timeout
    }
}

// MARK: Network space handlers
extension DeviceManager {
    private func markInitializedWithoutDevice() {
        if self.device != nil {
            self.clearDevice()
        } else {
            cleanupDeviceListeners()
            self.vpnManager?.close()
            self.vpnManager = nil
        }

        withDeviceStateLoad {
            self.provideControlMode = ProvideControlMode.Never
            self.allowProvidingCell = false
        }
        self.provideEnabled = false
        self.providePaused = false
        self.currentProvideMode = SdkProvideModeNone
        self.deviceInitialized = true
        self.updateParsedJwt()
    }

    private func clearAuthStateAndMarkInitialized() {
        self.api?.setByJwt(nil)

        guard let asyncLocalState = self.asyncLocalState else {
            self.removeVpnProfilesAndMarkInitializedWithoutDevice()
            return
        }

        let callback = SdkCommitCallback { success in
            DispatchQueue.main.async {
                if !success {
                    print("[\(self.domain)] failed to clear local auth state during initialization")
                }
                self.removeVpnProfilesAndMarkInitializedWithoutDevice()
            }
        }

        asyncLocalState.logout(callback)
    }

    private func removeVpnProfilesAndMarkInitializedWithoutDevice() {
        VPNManager.clearTunnelLocalStateAndRemoveAllVpnProfiles { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("[\(self.domain)] failed to remove VPN profiles during auth cleanup: \(error.localizedDescription)")
                }
                self.markInitializedWithoutDevice()
            }
        }
    }
    
    func initializeNetworkSpace() async {
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                   in: .userDomainMask)[0]
        let storagePath = documentsPath.path()
        
        let deviceSpecs = self.getDeviceSpecs()
        let networkSpaceManager = URnetworkSdk.SdkNewNetworkSpaceManager(storagePath)
        self.networkSpaceManager = networkSpaceManager
        
        let hostName = NetworkConfig.officialHostName
        let envName = NetworkConfig.officialEnvName
        let networkSpaceKey = URnetworkSdk.SdkNewNetworkSpaceKey(hostName, envName)
        
        networkSpaceManager?.updateNetworkSpace(networkSpaceKey, callback: NetworkSpaceUpdateCallback(
            c: { networkSpaceValues in
                networkSpaceValues.envSecret = NetworkConfig.envSecret
                networkSpaceValues.bundled = true
                networkSpaceValues.netExposeServerIps = NetworkConfig.netExposeServerIps
                networkSpaceValues.netExposeServerHostNames = NetworkConfig.netExposeServerHostNames
                networkSpaceValues.linkHostName = NetworkConfig.officialLinkHostName
                networkSpaceValues.migrationHostName = NetworkConfig.officialMigrationHostName
                networkSpaceValues.store = NetworkConfig.store
                networkSpaceValues.wallet = NetworkConfig.wallet
                networkSpaceValues.ssoGoogle = NetworkConfig.ssoGoogle
            }
        ))
            
        self.networkSpace = networkSpaceManager?.getNetworkSpace(networkSpaceKey)
        
        let getJwtCallback = GetJwtInitDeviceCallback(
            networkStore: self,
            deviceSpecs: deviceSpecs,
            onResult: { result, ok in
                if ok {
                    guard let result, !result.isEmpty else {
                        print("[\(self.domain)] stored client JWT is missing or empty")
                        self.clearAuthStateAndMarkInitialized()
                        return
                    }

                    self.initDeviceFromStoredAuthentication(
                        clientJwt: result,
                        deviceSpec: deviceSpecs
                    )
                } else {
                    self.markInitializedWithoutDevice()
                }
            }
        )
        guard let asyncLocalState = self.asyncLocalState else {
            self.markInitializedWithoutDevice()
            return
        }

        asyncLocalState.getByClientJwt(getJwtCallback)
        
    }
    
}

// MARK: Network server selection
@MainActor
extension DeviceManager {

    var activeHostName: String {
        networkSpace?.getHostName() ?? NetworkConfig.officialHostName
    }

    var activeApiUrl: String {
        networkSpace?.getApiUrl() ?? ""
    }

    var activePlatformUrl: String {
        networkSpace?.getPlatformUrl() ?? ""
    }

    var configuredApiUrl: String {
        networkSpace?.getConfiguredApiUrl() ?? ""
    }

    var configuredPlatformUrl: String {
        networkSpace?.getConfiguredPlatformUrl() ?? ""
    }

    /// Switches the active network space to `hostName`, deriving api/connect
    /// urls unless explicit overrides are given. Mirrors Android's
    /// `NetworkServerSelector`/`updateNetworkSpace` flow - both platforms
    /// share the same underlying Go `NetworkSpaceManager`.
    func applyNetworkSpace(
        hostName: String,
        apiUrl: String,
        connectUrl: String
    ) -> Bool {
        guard let networkSpaceManager else {
            return false
        }

        let isOfficial = hostName == NetworkConfig.officialHostName
        let hasExplicitUrls = !apiUrl.isEmpty || !connectUrl.isEmpty
        let key = URnetworkSdk.SdkNewNetworkSpaceKey(hostName, NetworkConfig.officialEnvName)

        let updated = networkSpaceManager.updateNetworkSpace(key, callback: NetworkSpaceUpdateCallback(
            c: { values in
                values.envSecret = NetworkConfig.envSecret
                values.bundled = isOfficial && !hasExplicitUrls
                values.netExposeServerIps = NetworkConfig.netExposeServerIps
                values.netExposeServerHostNames = NetworkConfig.netExposeServerHostNames
                values.linkHostName = isOfficial ? NetworkConfig.officialLinkHostName : hostName
                values.migrationHostName = isOfficial ? NetworkConfig.officialMigrationHostName : ""
                values.store = NetworkConfig.store
                values.wallet = NetworkConfig.wallet
                values.ssoGoogle = NetworkConfig.ssoGoogle
                values.apiUrl = apiUrl
                values.platformUrl = connectUrl
            }
        ))

        guard let updated else {
            return false
        }

        networkSpaceManager.setActiveNetworkSpace(updated)
        self.networkSpace = updated
        return true
    }
}

// MARK: Device handlers
@MainActor
extension DeviceManager {
    private func initDeviceFromStoredAuthentication(
        clientJwt: String,
        deviceSpec: String
    ) {
        let finishInitialization = { [weak self] (activeInstanceId: String?) in
            guard let self else { return }

            if let activeInstanceId {
                var parseError: NSError?
                let parsedInstanceId = SdkParseId(activeInstanceId, &parseError)
                if let parsedInstanceId, parseError == nil {
                    do {
                        try self.asyncLocalState?.getLocalState()?.setInstanceId(
                            parsedInstanceId
                        )
                        print("[DeviceManager]restored instance_id from active tunnel")
                    } catch {
                        print("[DeviceManager]failed to persist active tunnel instance_id: \(error.localizedDescription)")
                    }
                } else {
                    print("[DeviceManager]active tunnel has invalid instance_id: \(parseError?.localizedDescription ?? "unknown parse error")")
                }
            }

            if !self.initDevice(clientJwt: clientJwt, deviceSpec: deviceSpec) {
                self.clearAuthStateAndMarkInitialized()
            }
        }

        guard let networkSpace else {
            finishInitialization(nil)
            return
        }
        var networkSpaceError: NSError?
        let networkSpaceJson = networkSpace.toJson(&networkSpaceError)
        guard networkSpaceError == nil, !networkSpaceJson.isEmpty else {
            finishInitialization(nil)
            return
        }

        let rpcLoadResult = RpcSessionStore.loadResult()
        guard let rpcSession = rpcLoadResult.session else {
            switch rpcLoadResult {
            case .corrupt(let reason):
                print("[DeviceManager]RPC session is corrupt: \(reason)")
            case .unavailable(let reason):
                print("[DeviceManager]RPC session storage unavailable: \(reason)")
            case .missing, .pending, .confirmed:
                break
            }
            finishInitialization(nil)
            return
        }

        VPNManager.loadActiveTunnelBootstrapInstanceId(
            networkSpaceJson: networkSpaceJson,
            rpcSession: rpcSession,
            completion: finishInitialization
        )
    }
    
    func initDevice(
        clientJwt: String,
        deviceSpec: String
    ) -> Bool {
        guard let networkSpace = networkSpace else {
            markInitializedWithoutDevice()
            return false
        }

        guard let localState = asyncLocalState?.getLocalState() else {
            print("local state is nil")
            markInitializedWithoutDevice()
            return false
        }

        let routeLocal = localState.getRouteLocal()
        let blockerEnabled = localState.getBlockerEnabled()
        let connectLocation = localState.getConnectLocation()
        let defaultLocation = localState.getDefaultLocation()
        let canShowRatingDialog = localState.getCanShowRatingDialog()
        let canPromptIntroFunnel = localState.getCanPromptIntroFunnel()
        let allowForeground = localState.getAllowForeground()
        let performanceProfile = localState.getPerformanceProfile()

        let provideControlModeStr = localState.getProvideControlMode()
        let provideControlMode = ProvideControlMode(rawValue: provideControlModeStr)

        let provideNetworkModeStr = localState.getProvideNetworkMode()
        let provideNetworkMode = ProvideNetworkMode(rawValue: provideNetworkModeStr)

        let provideMode = provideControlMode == ProvideControlMode.Always ? SdkProvideModePublic : localState.getProvideMode()
        let canRefer = localState.getCanRefer()
        let vpnInterfaceWhileOffline = localState.getVpnInterfaceWhileOffline()

        var instanceId = localState.getInstanceId()
        if instanceId == nil {
            instanceId = SdkNewId()
            try? localState.setInstanceId(instanceId)
        }

        var newDeviceError: NSError?

        let device = SdkNewDeviceRemoteWithDefaults(
            networkSpace,
            clientJwt,
            instanceId,
            &newDeviceError
        )

        if let error = newDeviceError {
            print("Error occurred: \(error.localizedDescription)")
        } else {
            print("Device created successfully")
        }

        guard let device = device else {
            markInitializedWithoutDevice()
            return false
        }

        // Populate the shared restart credential on every authenticated cold
        // launch, not only when this build observes the next JWT rotation. For
        // upgraded installations the bootstrap above has already restored the
        // running profile's exact instance into LocalState, so this also closes
        // the one-restart migration gap for a token refreshed by an older build.
        if let activeInstanceId = device.getInstanceId()?.string(),
           !activeInstanceId.isEmpty {
            VPNManager.seedCurrentTunnelJwtIfMissing(
                clientJwt,
                instanceId: activeInstanceId
            )
        }

        // point the rpc transport at the last known good session (if any) so the
        // device can connect to an already-running extension immediately, instead
        // of the default 127.0.0.1:12025 ws until the vpn is (re)started
        if let rpcSession = RpcSessionStore.loadResult().session {
            do {
                try device.setRpcServer(rpcSession.clientPem, serverCertPem: rpcSession.serverCertPem, hostPort: rpcSession.hostPort)
            } catch {
                print("[DeviceManager]setRpcServer failed: \(error.localizedDescription)")
            }
        }

        // watch the provider's Network-mode key so the connect screen can show
        // whether this device is discoverable as a peer. Registered before the
        // load/init below so it receives the initial keys.
        providerNetworkKeySub?.close()
        providerNetworkKeySub = device.add(ProvideSecretKeysListener { provideSecretKeysList in
            let hasNetworkKey = DeviceManager.provideSecretKeysContainNetwork(provideSecretKeysList)
            DispatchQueue.main.async { [weak self] in
                self?.providerHasNetworkKey = hasNetworkKey
            }
        })

        if let providerSecretKeys = localState.getProvideSecretKeys() {
            device.loadProvideSecretKeys(providerSecretKeys)
        } else {
            var providerSecretKeysSub: SdkSubProtocol?
            providerSecretKeysSub = device.add(ProvideSecretKeysListener { provideSecretKeysList in
                try? localState.setProvideSecretKeys(provideSecretKeysList)
                providerSecretKeysSub?.close()
            })
            device.initProvideSecretKeys()
        }

        // load this device's editable network name (what peers see) for the
        // discoverable line on the connect screen
        Task { [weak self] in await self?.fetchDeviceName(device) }

        // note the network extension controls listening for connectivity and provide paused
        // ignore `providePaused`
        device.setRouteLocal(routeLocal)
        device.setProvideMode(provideMode)
        device.setCanShowRatingDialog(canShowRatingDialog)
        device.setCanPromptIntroFunnel(canPromptIntroFunnel)
        device.setAllowForeground(allowForeground)
        device.setProvideControlMode(provideControlMode?.rawValue ?? ProvideControlMode.Never.rawValue)
        device.setProvideNetworkMode(provideNetworkMode?.rawValue ?? ProvideNetworkMode.WiFi.rawValue)
        device.setCanRefer(canRefer)
        device.setVpnInterfaceWhileOffline(vpnInterfaceWhileOffline)
        device.setBlockerEnabled(blockerEnabled)
        withDeviceStateLoad {
            self.blockerEnabled = blockerEnabled
        }

        if (performanceProfile != nil) {
            device.setPerformanceProfile(performanceProfile)
        }

        // only set the location if the current location is not already equivalent
        // this avoid resetting the connection
        if let remoteLocation = device.getConnectLocation() {
            if !remoteLocation.equals(connectLocation) {
                device.setConnectLocation(connectLocation)
            }
        } else {
            device.setConnectLocation(connectLocation)
        }

        // default location is used to persist non-connected location on app restart
        if (defaultLocation != nil) {
            device.setDefaultLocation(defaultLocation)
        }

        // transport settings: the device (in the extension) persists and
        // restores its own policy, but the app and the extension do not share
        // storage, so an edit made while the tunnel was down would be lost on
        // relaunch. The app local state mirrors every edit
        // (TransportSettingsStore.apply); seed the remote from that mirror so
        // the edit is queued and applied on the next connect. Nothing stored
        // means never edited: leave the extension's persisted/default policy.
        if let transportSettings = localState.getTransportSettings() {
            device.setTransportSettings(transportSettings)
        }
        if let providerTransportSettings = localState.getProviderTransportSettings() {
            device.setProviderTransportSettings(providerTransportSettings)
        }

        self.setDevice(device: device)
        return true
    }
    
    
    private func getAppVersion() -> String? {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            print("App version: \(version)")
            return version
        }
        
        return nil
    }
    
    private func setupDeviceListeners() {
        guard let device = self.device else {
            return
        }
        
        
        print("setup device listeners")
        
        self.cleanupDeviceListeners()
        
        self.deviceProvidePausedSub = device.add(ProvidePausedChangeListener { [weak self] providePaused in
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                self.providePaused = providePaused
            }
        })
        
        self.deviceProvideSub = device.add(ProvideChangeListener { [weak self] provideEnabled in
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                self.provideEnabled = provideEnabled
            }
        })
        
        self.deviceJwtRefreshSub = device.add(JwtRefreshListener { [weak self] jwt in
            guard let self = self else {
                return
            }

            DispatchQueue.main.async {
                self.updateParsedJwt()
                guard let jwt, !jwt.isEmpty,
                      let instanceId = device.getInstanceId()?.string(),
                      !instanceId.isEmpty else {
                    return
                }
                VPNManager.persistRefreshedTunnelJwt(
                    jwt,
                    instanceId: instanceId
                )
            }

        })

        // the sdk fires this when the jwt refresh finds the client no longer
        // exists on the server (e.g. the client was removed): the sdk has
        // already cleared its local auth state; log the user out so the ui
        // returns to the login flow
        self.deviceAuthLogoutSub = device.add(AuthLogoutListener { [weak self] in

            print("AuthLogoutListener hit")

            guard let self = self else {
                return
            }

            DispatchQueue.main.async {
                self.logout()
            }

        })

        self.deviceCanShowRatingDialogSub = device.add(CanShowRatingDialogChangeListener { [weak self] canShowRatingDialog in
            try? self?.asyncLocalState?.getLocalState()?.setCanShowRatingDialog(canShowRatingDialog)
        })

        self.deviceCanPromptIntroFunnelSub = device.add(CanPromptIntroFunnelChangeListener { [weak self] canPromptIntroFunnel in
            try? self?.asyncLocalState?.getLocalState()?.setCanPromptIntroFunnel(canPromptIntroFunnel)
        })

        self.deviceAllowForegroundSub = device.add(AllowForegroundChangeListener { [weak self] allowForeground in
            try? self?.asyncLocalState?.getLocalState()?.setAllowForeground(allowForeground)
        })

        self.deviceBlockerEnabledSub = device.add(BlockerEnabledChangeListener { [weak self] blockerEnabled in
            guard let self = self else {
                return
            }

            DispatchQueue.main.async {
                if self.blockerEnabled != blockerEnabled {
                    self.withDeviceStateLoad {
                        self.blockerEnabled = blockerEnabled
                    }
                }
            }
        })

        self.deviceCanReferSub = device.add(CanReferChangeListener { [weak self] canRefer in
            try? self?.asyncLocalState?.getLocalState()?.setCanRefer(canRefer)
        })

        self.deviceProvideModeSub = device.add(ProvideModeChangeListener { [weak self] provideMode in
            try? self?.asyncLocalState?.getLocalState()?.setProvideMode(provideMode)
            DispatchQueue.main.async { [weak self] in
                self?.currentProvideMode = provideMode
            }
        })

        self.deviceProvideNetworkModeSub = device.add(ProvideNetworkModeChangeListener { [weak self] provideNetworkMode in
            guard let provideNetworkMode else {
                return
            }
            try? self?.asyncLocalState?.getLocalState()?.setProvideNetworkMode(provideNetworkMode)
        })

        self.deviceVpnInterfaceWhileOfflineSub = device.add(VpnInterfaceWhileOfflineChangeListener { [weak self] vpnInterfaceWhileOffline in
            try? self?.asyncLocalState?.getLocalState()?.setVpnInterfaceWhileOffline(vpnInterfaceWhileOffline)
        })

        self.deviceDefaultLocationSub = device.add(DefaultLocationChangeListener { [weak self] location in
            try? self?.asyncLocalState?.getLocalState()?.setDefaultLocation(location)
        })
        
        self.provideEnabled = device.getProvideEnabled()
        self.providePaused = device.getProvidePaused()
        self.currentProvideMode = device.getProvideMode()
    }

    private func cleanupDeviceListeners() {
        deviceProvideSub?.close()
        deviceProvideSub = nil
        
        deviceProvidePausedSub?.close()
        deviceProvidePausedSub = nil
        
        deviceJwtRefreshSub?.close()
        deviceJwtRefreshSub = nil

        deviceAuthLogoutSub?.close()
        deviceAuthLogoutSub = nil

        deviceCanShowRatingDialogSub?.close()
        deviceCanShowRatingDialogSub = nil

        deviceCanPromptIntroFunnelSub?.close()
        deviceCanPromptIntroFunnelSub = nil

        deviceAllowForegroundSub?.close()
        deviceAllowForegroundSub = nil

        deviceCanReferSub?.close()
        deviceCanReferSub = nil

        deviceProvideModeSub?.close()
        deviceProvideModeSub = nil

        deviceProvideNetworkModeSub?.close()
        deviceProvideNetworkModeSub = nil

        deviceVpnInterfaceWhileOfflineSub?.close()
        deviceVpnInterfaceWhileOfflineSub = nil

        deviceDefaultLocationSub?.close()
        deviceDefaultLocationSub = nil

        deviceBlockerEnabledSub?.close()
        deviceBlockerEnabledSub = nil

        providerNetworkKeySub?.close()
        providerNetworkKeySub = nil
        providerHasNetworkKey = false
        deviceName = ""
        currentProvideMode = SdkProvideModeNone
    }

    private static func provideSecretKeysContainNetwork(_ list: SdkProvideSecretKeyList?) -> Bool {
        guard let list = list else { return false }
        for i in 0..<list.len() {
            if let key = list.get(i), key.provideMode == SdkProvideModeNetwork {
                return true
            }
        }
        return false
    }

    private func fetchDeviceName(_ device: SdkDeviceRemote) async {
        guard let clientId = device.getClientId(), let api = self.api else { return }
        do {
            // self.api is the raw SdkApi, whose generated call is callback-based
            let result: SdkNetworkClientsResult = try await withCheckedThrowingContinuation { continuation in
                let callback = FetchNetworkClientsCallback { result, err in
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    guard let result = result else {
                        continuation.resume(throwing: NSError(
                            domain: "DeviceManager",
                            code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "empty network clients result"]
                        ))
                        return
                    }
                    continuation.resume(returning: result)
                }
                api.getNetworkClients(callback)
            }
            guard let clients = result.clients else { return }
            for i in 0..<clients.len() {
                guard let info = clients.get(i) else { continue }
                if info.clientId?.idStr == clientId.idStr {
                    self.deviceName = !info.deviceName.isEmpty ? info.deviceName : info.deviceDescription
                    break
                }
            }
        } catch {
            print("[\(domain)] Error fetching device name: \(error)")
        }
    }

}

private class FetchNetworkClientsCallback: SdkCallback<
    SdkNetworkClientsResult, SdkGetNetworkClientsCallbackProtocol
>, SdkGetNetworkClientsCallbackProtocol
{
    func result(_ result: SdkNetworkClientsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class AuthNetworkClientCallback: SdkCallback<SdkAuthNetworkClientResult, SdkAuthNetworkClientCallbackProtocol>, SdkAuthNetworkClientCallbackProtocol {
    func result(_ result: SdkAuthNetworkClientResult?, err: Error?) {
        
        DispatchQueue.main.async {
            self.handleResult(result, err: err)
        }
    }
}

private class SetJWTLocalStateCallback: NSObject, SdkCommitCallbackProtocol {
    
    let continuation: CheckedContinuation<Void, Error>
    let clientJwt: String
    let deviceSpecs: String
    let initDevice: (_ clientJwt: String, _ deviceSpecs: String) -> Bool
    
    init(
        continuation: CheckedContinuation<Void, Error>,
        clientJwt: String,
        deviceSpecs: String,
        initDevice: @escaping (_ clientJwt: String, _ deviceSpecs: String) -> Bool
    ) {
        self.continuation = continuation
        
        self.initDevice = initDevice
        
        self.clientJwt = clientJwt
        self.deviceSpecs = deviceSpecs
    }
    
    func complete(_ success: Bool) {
        DispatchQueue.main.async {
            
            if success {
                if self.initDevice(self.clientJwt, self.deviceSpecs) {
                    self.continuation.resume(returning: ())
                } else {
                    self.continuation.resume(throwing: NSError(domain: "SetJWTLocalStateCallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize device"]))
                }
                
            } else {
                self.continuation.resume(throwing: NSError(domain: "SetJWTLocalStateCallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to set client JWT"]))
            }
        }
        
    }
}


// MARK: login/logout
@MainActor
extension DeviceManager {
    
    func authenticateNetworkClient(_ jwt: String) async -> Result<Void, Error> {
        guard let asyncLocalState = asyncLocalState,
              let localState = asyncLocalState.getLocalState() else {
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "login: local state is nil"]))
        }

        do {
            try localState.setByJwt(jwt)
        } catch {
            return .failure(error)
        }
        
        guard let api = api else {
            await rollbackFailedNetworkClientAuthentication()
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "login: api is nil"]))
        }
        
        api.setByJwt(jwt)
        
        // NOTE: the following was in authClientAndFinish in Android
        // not sure if we need to keep these as separate functions
        
        do {
            
            let deviceSpecs = getDeviceSpecs()
            
            let result: Void = try await withCheckedThrowingContinuation { continuation in
                
                let authArgs = SdkAuthNetworkClientArgs()
                authArgs.deviceDescription = deviceDescription
                authArgs.deviceSpec = deviceSpecs
                
                let callback = AuthNetworkClientCallback { [weak self] result, error in
                    guard let self = self else { return }
                    
                    
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "No result found in AuthNetworkClientCallback"]))
                        return
                    }
                    
                    if let resultError = result.error {
                        continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                        
                        return
                    }
                    
                    let clientJwt = result.byClientJwt
                    guard !clientJwt.isEmpty else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Auth network client returned empty client JWT"]))
                        return
                    }

                    let callback = SetJWTLocalStateCallback(
                        continuation: continuation,
                        clientJwt: clientJwt,
                        deviceSpecs: deviceSpecs,
                        initDevice: self.initDevice(clientJwt:deviceSpec:)
                    )
                    
                    asyncLocalState.setByClientJwt(clientJwt, callback: callback)
                    
                }
                
                api.authNetworkClient(authArgs, callback: callback)
                
            }
            
            return .success(result)
            
        } catch {
            await rollbackFailedNetworkClientAuthentication()
            return .failure(error)
        }
        
    }

    private func rollbackFailedNetworkClientAuthentication() async {
        api?.setByJwt(nil)

        guard let asyncLocalState = asyncLocalState else {
            return
        }

        await withCheckedContinuation { continuation in
            let callback = SdkCommitCallback { success in
                if !success {
                    print("[authenticateNetworkClient] failed to roll back BY-JWT")
                }

                let clientJwtCallback = SdkCommitCallback { success in
                    if !success {
                        print("[authenticateNetworkClient] failed to roll back client JWT")
                    }
                    continuation.resume()
                }

                asyncLocalState.setByClientJwt(nil, callback: clientJwtCallback)
            }

            asyncLocalState.setByJwt(nil, callback: callback)
        }
    }
    
    class SdkCommitCallback: NSObject, SdkCommitCallbackProtocol {
        let completionHandler: (Bool) -> Void
        
        init(completionHandler: @escaping (Bool) -> Void) {
            self.completionHandler = completionHandler
            super.init()
        }
        
        func complete(_ success: Bool) {
            completionHandler(success)
        }
    }
    
    func logout() {
        guard !isLoggingOut else {
            return
        }

        isLoggingOut = true
        SharedTunnelJwtStore.clear()

        let finishLocalStateLogout = {
            guard let asyncLocalState = self.asyncLocalState else {
                print("[logout] asyncLocalState is nil")
                self.isLoggingOut = false
                self.clearDevice()
                return
            }

            let callback = SdkCommitCallback { success in
                DispatchQueue.main.async {
                    self.isLoggingOut = false
                    if !success {
                        print("[logout] asyncLocalState logout failed")
                    }
                    self.clearDevice()
                }
            }

            asyncLocalState.logout(callback)
        }

        guard let vpnManager = vpnManager else {
            VPNManager.clearTunnelLocalStateAndRemoveAllVpnProfiles { error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("[logout] failed to clear VPN profiles: \(error.localizedDescription)")
                    }
                    finishLocalStateLogout()
                }
            }
            return
        }

        vpnManager.stopVpnTunnelOnLogout { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("[logout] failed to stop VPN tunnel: \(error.localizedDescription)")
                }

                vpnManager.close()
                if self.vpnManager === vpnManager {
                    self.vpnManager = nil
                }

                finishLocalStateLogout()
            }
        }
    }
    
    // concise, human-readable spec shown in the peers list:
    // "<os> <retail model>", e.g. "18.5 iPhone 16 Pro Max",
    // "15.5 MacBook Pro (16-inch, Nov 2023)". `UIDevice.model` is just
    // "iPhone", and `UIDevice.name` has been the generic "iPhone" since
    // iOS 16 — the old spec read "iPhone iPhone". The retail name comes
    // from the hardware identifier via the bundled `DeviceModelNames`
    // table; unknown (newer) identifiers fall back to the identifier
    // itself ("iPhone19,1"), which still names the device
    private func getDeviceSpecs() -> String {
        var systemVersion = ""

        #if os(iOS)
        systemVersion = UIDevice.current.systemVersion
        #elseif os(macOS)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        #endif

        let model = Self.deviceModelName()
        return "\(systemVersion) \(model)"
    }

    // the hardware model identifier: "iPhone17,2" on ios (utsname.machine),
    // "Mac15,7" on macos (sysctl hw.model, since utsname.machine is the
    // cpu arch there). On the simulator the machine reports the host arch;
    // use the simulator's model environment instead
    private static func hardwareModelIdentifier() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if 0 < size {
            var machine = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &machine, &size, nil, 0)
            return String(cString: machine)
        }
        return "Mac"
        #else
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let bytes = buffer.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        #endif
    }
    
}


private class ProvideSecretKeysListener: NSObject, SdkProvideSecretKeysListenerProtocol {
    
    private let c: (_ provideSecretKeysList: SdkProvideSecretKeyList?) -> Void

    init(c: @escaping (_ provideSecretKeysList: SdkProvideSecretKeyList?) -> Void) {
        self.c = c
    }
    
    func provideSecretKeysChanged(_ provideSecretKeysList: SdkProvideSecretKeyList?) {
        
        DispatchQueue.main.async {
            self.c(provideSecretKeysList)
        }
    }
}

private class ProvideChangeListener: NSObject, SdkProvideChangeListenerProtocol {
    
    private let c: (_ provideEnabled: Bool) -> Void

    init(c: @escaping (_ provideEnabled: Bool) -> Void) {
        self.c = c
    }
    
    func provideChanged(_ provideEnabled: Bool) {
        c(provideEnabled)
    }
}

private class ProvidePausedChangeListener: NSObject, SdkProvidePausedChangeListenerProtocol {

    private let c: (_ providePaused: Bool) -> Void

    init(c: @escaping (_ providePaused: Bool) -> Void) {
        self.c = c
    }

    func providePausedChanged(_ providePaused: Bool) {
        c(providePaused)
    }
}

private class BlockerEnabledChangeListener: NSObject, SdkBlockerEnabledChangeListenerProtocol {

    private let c: (_ blockerEnabled: Bool) -> Void

    init(c: @escaping (_ blockerEnabled: Bool) -> Void) {
        self.c = c
    }

    func blockerEnabledChanged(_ blockerEnabled: Bool) {
        c(blockerEnabled)
    }
}

private class CanShowRatingDialogChangeListener: NSObject, SdkCanShowRatingDialogChangeListenerProtocol {

    private let c: (_ canShowRatingDialog: Bool) -> Void

    init(c: @escaping (_ canShowRatingDialog: Bool) -> Void) {
        self.c = c
    }

    func canShowRatingDialogChanged(_ canShowRatingDialog: Bool) {
        c(canShowRatingDialog)
    }
}

private class CanPromptIntroFunnelChangeListener: NSObject, SdkCanPromptIntroFunnelChangeListenerProtocol {

    private let c: (_ canPromptIntroFunnel: Bool) -> Void

    init(c: @escaping (_ canPromptIntroFunnel: Bool) -> Void) {
        self.c = c
    }

    func canPromptIntroFunnelChanged(_ canPromptIntroFunnel: Bool) {
        c(canPromptIntroFunnel)
    }
}

private class AllowForegroundChangeListener: NSObject, SdkAllowForegroundChangeListenerProtocol {

    private let c: (_ allowForeground: Bool) -> Void

    init(c: @escaping (_ allowForeground: Bool) -> Void) {
        self.c = c
    }

    func allowForegroundChanged(_ allowForeground: Bool) {
        c(allowForeground)
    }
}

private class CanReferChangeListener: NSObject, SdkCanReferChangeListenerProtocol {

    private let c: (_ canRefer: Bool) -> Void

    init(c: @escaping (_ canRefer: Bool) -> Void) {
        self.c = c
    }

    func canReferChanged(_ canRefer: Bool) {
        c(canRefer)
    }
}

private class ProvideModeChangeListener: NSObject, SdkProvideModeChangeListenerProtocol {

    private let c: (_ provideMode: Int) -> Void

    init(c: @escaping (_ provideMode: Int) -> Void) {
        self.c = c
    }

    func provideModeChanged(_ provideMode: Int) {
        c(provideMode)
    }
}

private class ProvideNetworkModeChangeListener: NSObject, SdkProvideNetworkModeChangeListenerProtocol {

    private let c: (_ provideNetworkMode: String?) -> Void

    init(c: @escaping (_ provideNetworkMode: String?) -> Void) {
        self.c = c
    }

    func provideNetworkModeChanged(_ provideNetworkMode: String?) {
        c(provideNetworkMode)
    }
}

private class VpnInterfaceWhileOfflineChangeListener: NSObject, SdkVpnInterfaceWhileOfflineChangeListenerProtocol {

    private let c: (_ vpnInterfaceWhileOffline: Bool) -> Void

    init(c: @escaping (_ vpnInterfaceWhileOffline: Bool) -> Void) {
        self.c = c
    }

    func vpnInterfaceWhileOfflineChanged(_ vpnInterfaceWhileOffline: Bool) {
        c(vpnInterfaceWhileOffline)
    }
}

private class DefaultLocationChangeListener: NSObject, SdkDefaultLocationChangeListenerProtocol {

    private let c: (_ location: SdkConnectLocation?) -> Void

    init(c: @escaping (_ location: SdkConnectLocation?) -> Void) {
        self.c = c
    }

    func defaultLocationChanged(_ location: SdkConnectLocation?) {
        c(location)
    }
}

private class JwtRefreshListener: NSObject, SdkJwtRefreshListenerProtocol {

    private let c: (_ jwt: String?) -> Void

    init(c: @escaping (_ jwt: String?) -> Void) {
        self.c = c
    }

    func jwtRefreshed(_ jwt: String?) {
        c(jwt)
    }
}

private class AuthLogoutListener: NSObject, SdkAuthLogoutListenerProtocol {

    private let c: () -> Void

    init(c: @escaping () -> Void) {
        self.c = c
    }

    func authLogout() {
        c()
    }
}
