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
#if os(iOS)
import BackgroundTasks
#endif

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

/// Which network space the app binds to on launch.
///
/// The SDK persists the active space across launches, so the app must READ that
/// back rather than re-deriving it from the bundled key. The bundled space is
/// forced active only in the two cases where there is nothing to honour: it was
/// just created (first install, or a migration to a newer bundle), or no active
/// space is recorded at all. Any other launch keeps whatever the user chose.
///
/// Parity source: android's `MainApplication.kt`
///     `if (!bundleNetworkSpaceExists || networkSpaceManager?.activeNetworkSpace == null)`
/// This is a pure function so the boolean itself is testable -- the iOS side of
/// it diverged from android unnoticed precisely because it was inlined.
struct NetworkSpaceSelection {
    static func shouldActivateBundled(bundledSpaceExisted: Bool, hasActiveSpace: Bool) -> Bool {
        !bundledSpaceExisted || !hasActiveSpace
    }
}

/// The launch sequence that prepares the bundled network space and answers
/// which space the app binds to. It runs against a freshly opened
/// `SdkNetworkSpaceManager` and holds no `SdkNetworkSpace` before the legacy
/// key has been migrated, so the order is the contract:
///
///   1. `migrateNetworkSpace(ur.network/main -> bringyour.com/main)`. The
///      operator stays bringyour.com; builds before that decision bundled the
///      official space under key host ur.network with bringyour.com as the
///      migration host, so an existing install's credentials and settings sit
///      under `network_spaces/ur.network/main`. The SDK moves that state to the
///      official key once; it answers false on a fresh install and on every
///      later launch (the destination key already exists), so this is
///      idempotent and nothing is lost if the destination already holds state.
///      It MUST run before `updateNetworkSpace` creates the bundled key, or the
///      migration finds the destination taken and the install is signed out.
///   2. Create or refresh the bundled space under the official key.
///   3. `NetworkSpaceSelection` decides whether the bundled space is forced
///      active; otherwise the persisted active space (the user's choice) wins.
struct NetworkSpaceStartup {
    static var legacyBundledKey: SdkNetworkSpaceKey? {
        URnetworkSdk.SdkNewNetworkSpaceKey(NetworkConfig.legacyOfficialHostName, NetworkConfig.officialEnvName)
    }

    static var bundledKey: SdkNetworkSpaceKey? {
        URnetworkSdk.SdkNewNetworkSpaceKey(NetworkConfig.officialHostName, NetworkConfig.officialEnvName)
    }

    @discardableResult
    static func migrateLegacyBundledNetworkSpace(_ networkSpaceManager: SdkNetworkSpaceManager) -> Bool {
        networkSpaceManager.migrateNetworkSpace(legacyBundledKey, to: bundledKey)
    }

    /// Returns the space the app binds to, or nil when the manager cannot
    /// produce one at all.
    static func prepareBundledNetworkSpace(_ networkSpaceManager: SdkNetworkSpaceManager) -> SdkNetworkSpace? {
        migrateLegacyBundledNetworkSpace(networkSpaceManager)

        let networkSpaceKey = bundledKey

        // Sampled BEFORE updateNetworkSpace, which creates the bundled space when it
        // is missing -- asking afterwards would always answer "it existed".
        // Mirrors the sample android takes in MainApplication.kt.
        let bundledSpaceExisted = networkSpaceManager.getNetworkSpace(networkSpaceKey) != nil

        // Refreshing the bundled values on every launch is intentional: it migrates a
        // space created by an older bundle up to this build's constants, exactly as
        // android does. What must NOT be derived from the bundled key is which space
        // the app then binds to.
        let bundledNetworkSpace = networkSpaceManager.updateNetworkSpace(networkSpaceKey, callback: NetworkSpaceUpdateCallback(
            c: { networkSpaceValues in
                networkSpaceValues.envSecret = NetworkConfig.envSecret
                networkSpaceValues.bundled = true
                networkSpaceValues.netExposeServerIps = NetworkConfig.netExposeServerIps
                networkSpaceValues.netExposeServerHostNames = NetworkConfig.netExposeServerHostNames
                networkSpaceValues.linkHostName = NetworkConfig.officialLinkHostName
                networkSpaceValues.migrationHostName = ""
                networkSpaceValues.store = NetworkConfig.store
                networkSpaceValues.wallet = NetworkConfig.wallet
                networkSpaceValues.ssoGoogle = NetworkConfig.ssoGoogle
            }
        ))

        // Parity with android's MainApplication.kt -- force the bundled space active
        // ONLY when it was just created or when nothing is active yet.
        //
        // Without this the app bound the bundled key on every launch and never read
        // the space the SDK had persisted, so a user who had selected a different
        // network space lost both their session and their API host on every restart:
        // `asyncLocalState` derives from `self.networkSpace`, so the startup jwt read
        // went to the BUNDLED space's per-host state directory while the credentials
        // sat unread under the selected space's, and the bundled space's values were
        // re-stamped over the selected API URL.
        if NetworkSpaceSelection.shouldActivateBundled(
            bundledSpaceExisted: bundledSpaceExisted,
            hasActiveSpace: networkSpaceManager.getActiveNetworkSpace() != nil
        ), let bundledNetworkSpace {
            networkSpaceManager.setActiveNetworkSpace(bundledNetworkSpace)
        }

        // The fallback is load-bearing, not decorative: if the persisted network space
        // state is corrupt or unreadable the active lookup returns nil, and without it
        // the app would come up bound to no space at all -- no api, no auth, no way
        // back.
        return networkSpaceManager.getActiveNetworkSpace()
            ?? networkSpaceManager.getNetworkSpace(networkSpaceKey)
    }
}

// Only device-auth callbacks cross this seam. The normal source is the actual
// SDK remote; tests retain the same registered callbacks without starting RPC.
protocol DeviceAuthCallbackSource: AnyObject {
    func authCallbackInstanceId() -> String?
    func observeAuthRefresh(_ callback: @escaping @Sendable (String?) -> Void) -> () -> Void
    /// `callback` gets the logout's cause (Device.GetAuthLogoutCause), read
    /// as the SDK fires the listener.
    func observeAuthLogout(_ callback: @escaping @Sendable (_ cause: String) -> Void) -> () -> Void
}

extension SdkDeviceRemote: DeviceAuthCallbackSource {
    func authCallbackInstanceId() -> String? { getInstanceId()?.string() }

    func observeAuthRefresh(_ callback: @escaping @Sendable (String?) -> Void) -> () -> Void {
        let subscription = add(JwtRefreshListener(c: callback))
        return { subscription?.close() }
    }

    func observeAuthLogout(_ callback: @escaping @Sendable (_ cause: String) -> Void) -> () -> Void {
        // the device sets the cause before its listeners run and a new sign-in
        // clears it, so it is read here, on the SDK's thread, before any hop
        let subscription = add(AuthLogoutListener(c: { [weak self] in
            callback(self?.getAuthLogoutCause() ?? "")
        }))
        return { subscription?.close() }
    }
}

// Only the provider extender status and setting cross this seam (EXTENDER.md
// N2, N7), with the lag.dev measurements setting that rides on the role
// (lag.dev/PLAN.md C4). The normal source is the SDK remote; tests keep the
// registered callback and record the writes without starting RPC.
protocol ExtenderProvideSource: AnyObject {
    func readExtenderProvideStatus() -> ExtenderProvideStatusModel
    func readProvideExtender() -> Bool
    func writeProvideExtender(_ provideExtender: Bool)
    func readMeasurementsEnabled() -> Bool
    func writeMeasurementsEnabled(_ measurementsEnabled: Bool)
    func observeExtenderProvideStatus(
        _ callback: @escaping @Sendable (ExtenderProvideStatusModel) -> Void
    ) -> () -> Void
}

extension SdkDeviceRemote: ExtenderProvideSource {
    func readExtenderProvideStatus() -> ExtenderProvideStatusModel {
        getExtenderProvideStatus().map { ExtenderProvideStatusModel($0) } ?? .unsupported
    }

    func readProvideExtender() -> Bool {
        getProvideExtender()
    }

    func writeProvideExtender(_ provideExtender: Bool) {
        setProvideExtender(provideExtender)
    }

    func readMeasurementsEnabled() -> Bool {
        getMeasurementsEnabled()
    }

    func writeMeasurementsEnabled(_ measurementsEnabled: Bool) {
        setMeasurementsEnabled(measurementsEnabled)
    }

    func observeExtenderProvideStatus(
        _ callback: @escaping @Sendable (ExtenderProvideStatusModel) -> Void
    ) -> () -> Void {
        // the sdk hands a listener the unsupported status, never nil
        let subscription = add(ExtenderProvideStatusChangeListener { status in
            guard let status else { return }
            callback(ExtenderProvideStatusModel(status))
        })
        return { subscription?.close() }
    }
}

typealias DeviceAuthCallbackWork = @MainActor @Sendable () -> Void
typealias DeviceAuthCallbackDispatch = @Sendable (@escaping DeviceAuthCallbackWork) -> Void

// Side effects remain the existing implementations. Injected sinks let the
// callback admission tests avoid Keychain and NetworkExtension preferences.
struct DeviceAuthCallbackEffects {
    let persistRefresh: @MainActor (String, String) -> Void
    let logout: @MainActor (DeviceManager) -> Void

    static var live: DeviceAuthCallbackEffects {
        DeviceAuthCallbackEffects(
            persistRefresh: { jwt, instanceId in
                VPNManager.persistRefreshedTunnelJwt(jwt, instanceId: instanceId)
            },
            logout: { manager in manager.logout() }
        )
    }
}

// Reference identity names one registration, even when device/token bytes are
// reused. Only the main actor reads or changes the manager's current owner.
private final class DeviceAuthCallbackOwner: Sendable {}

// One registration of the provider extender status listener, as above.
private final class ExtenderProvideCallbackOwner: Sendable {}

/// Storage or device preparation can be retried without ending the saved session.
enum StoredAuthenticationStartupState {
    case loading
    case retryableFailure
    case settled
}

/// One startup attempt owns its bootstrap completion, even for equal credentials.
@MainActor
private final class StoredAuthenticationStartupOwner {
    var completed = false
}

/// One accepted registration retains its resources across the API suspension.
@MainActor
private final class NetworkClientAuthenticationOwner {
    let networkSpace: SdkNetworkSpace
    let localState: SdkLocalState
    let api: SdkApi

    init(networkSpace: SdkNetworkSpace, localState: SdkLocalState, api: SdkApi) {
        self.networkSpace = networkSpace
        self.localState = localState
        self.api = api
    }
}

/// Global profile cleanup excludes new auth until its original local cleanup joins.
@MainActor
private final class DeviceLogoutOwner {
    let networkSpace: SdkNetworkSpace?
    let api: SdkApi?
    let localState: SdkAsyncLocalState?
    let device: SdkDeviceRemote?
    let vpnManager: VPNManager?
    var profilesCompleted = false
    var profilesSucceeded = false
    var localStateCompleted = false

    init(manager: DeviceManager) {
        networkSpace = manager.networkSpace
        api = manager.api
        localState = manager.asyncLocalState
        device = manager.device
        vpnManager = manager.vpnManager
    }
}

/// Only external cleanup is replaceable; owner admission and finalization stay live.
struct DeviceLogoutEffects {
    let clearTunnelCredential: @MainActor () -> Void
    let removeProfiles: @MainActor (VPNManager?, @escaping (Error?) -> Void) -> Void
    let clearLocalState: @MainActor (SdkAsyncLocalState, SdkCommitCallbackProtocol) -> Void

    static var live: DeviceLogoutEffects {
        DeviceLogoutEffects(
            clearTunnelCredential: { SharedTunnelJwtStore.clear() },
            removeProfiles: { manager, completion in
                if let manager {
                    manager.stopVpnTunnelOnLogout(completion: completion)
                } else {
                    VPNManager.clearTunnelLocalStateAndRemoveAllVpnProfiles(completion: completion)
                }
            },
            clearLocalState: { state, callback in state.logout(callback) }
        )
    }
}

@MainActor
class DeviceManager: ObservableObject {
    
    let domain = "GlobalStore"
    let startupMode: AppStartupMode
    private(set) var startupInitializationInvocationCount = 0
    private(set) var vpnManagerInitializationInvocationCount = 0
    
    @Published private(set) var networkSpace: SdkNetworkSpace? {
        didSet {
            retireDeviceAuthCallbacks()
            retireStoredAuthenticationStartup()
            networkClientAuthenticationOwner = nil
            retireNetworkLoginRequests()
//            setApi(networkSpace?.getApi())
            // updateParsedJwt()
            // each space owns its own api: report this app's device type and
            // version with its calls (Account > Sessions shows them), before
            // a device is built on the space
            AppClientInfo.apply(to: networkSpace?.getApi())
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
    
    @Published private(set) var vpnManager: VPNManager? = nil {
        didSet {
            guard let vpnManager else { return }
            if applicationIsActive {
                vpnManager.applicationDidBecomeActive()
            } else {
                vpnManager.applicationDidBecomeInactive()
            }
        }
    }
    private var applicationIsActive = false
    private var isLoggingOut = false
    private var networkClientAuthenticationOwner: NetworkClientAuthenticationOwner?
    @Published private(set) var networkLoginOrigin = NetworkLoginOrigin()
    private var pendingNetworkLoginRequest: NetworkLoginRequest?
    private var acceptedNetworkLoginRequest: NetworkLoginRequest?
    private var logoutOwner: DeviceLogoutOwner?
    private let logoutEffects: DeviceLogoutEffects
    /// Runs as a logout of a device begins, whoever started it (the app's
    /// Sign out, the account deletion, the server), before anything is torn
    /// down: the connect view model stops connecting that device
    /// (signOutStarted). A logout with no device has nothing to stop, and
    /// no device change would end the sign out.
    var logoutStarted: (@MainActor (SdkDeviceRemote) -> Void)?

    /// Why the server signed this app out, when the device's logout gave a
    /// cause that has a notice: the sign-in screen shows it once, until the
    /// user dismisses it. A new login clears it.
    @Published private(set) var signedOutNotice: SignedOutNotice? = nil

    private var deviceAuthCallbackOwner: DeviceAuthCallbackOwner?
    private let authCallbackDispatch: DeviceAuthCallbackDispatch
    private let authCallbackEffects: DeviceAuthCallbackEffects
    private let extenderProvideCallbackDispatch: DeviceAuthCallbackDispatch
    private var storedAuthenticationStartupOwner: StoredAuthenticationStartupOwner?
    @Published private(set) var storedAuthenticationStartupState: StoredAuthenticationStartupState = .loading

    func applicationDidBecomeActive() {
        applicationIsActive = true
        vpnManager?.applicationDidBecomeActive()
    }

    func applicationDidBecomeInactive() {
        applicationIsActive = false
        vpnManager?.applicationDidBecomeInactive()
    }

    #if os(iOS)
    func handleBackgroundUpdate(task: BGTask) {
        let finisher = VPNBackgroundTaskFinisher(task: task)
        task.expirationHandler = {
            finisher.finish(success: false)
        }

        Task { @MainActor [weak self] in
            let managerDeadline = Date().addingTimeInterval(10)
            while !finisher.isFinished, Date() < managerDeadline {
                guard let self else {
                    finisher.finish(success: false)
                    return
                }
                if let vpnManager = self.vpnManager {
                    vpnManager.handleBackgroundUpdate(
                        task: task,
                        finisher: finisher
                    )
                    return
                }
                if self.deviceInitialized {
                    // Initialization completed without an authenticated device,
                    // so there is no tunnel state this refresh can reconcile.
                    finisher.finish(success: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            finisher.finish(success: false)
        }
    }
    #endif
    
    
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
    
    /// The provider extender role as the device reports it (EXTENDER.md N2,
    /// N7): what the Extender rows draw and, through `enabled`, whether the
    /// extender statistics show (O8). Unsupported until a device reports, and
    /// again when the device goes.
    @Published private(set) var extenderProvideStatus: ExtenderProvideStatusModel = .unsupported

    /// The provider extender setting (N4), the Extender switch's position. A
    /// toggle writes it through the device at once; every pushed status reads
    /// it back from the device under the echo guard, and a device process out
    /// of contact answers the queued value, so the switch never snaps back
    /// during a daemon restart (N2). On before any read, as the sdk's default.
    @Published var provideExtender: Bool = true {
        didSet {
            guard DeviceSettingWritePolicy.shouldPropagate(
                isLoadingFromDevice: isLoadingFromDevice
            ) else { return }
            handleProvideExtenderUpdate(provideExtender)
        }
    }

    /// The lag.dev measurements setting (lag.dev/PLAN.md C4, decision 18), the
    /// speed tests switch under the Extender row: whether the role serves the
    /// measurement API. Read and written as the provider extender setting is,
    /// through the device, which stores it and applies it at once, and only
    /// while the role is supported. On before any read, as the sdk's default.
    @Published var measurementsEnabled: Bool = true {
        didSet {
            guard DeviceSettingWritePolicy.shouldPropagate(
                isLoadingFromDevice: isLoadingFromDevice
            ) else { return }
            handleMeasurementsEnabledUpdate(measurementsEnabled)
        }
    }

    /// The Extender row's local repaint after a toggle, standing until the
    /// next pushed status replaces it (N7).
    @Published private(set) var extenderProvideGuess: ExtenderProvideDisplay? = nil

    /// What the Extender rows draw: the toggle's guess until the next status
    /// arrives, else the reading of the status.
    var extenderProvideDisplay: ExtenderProvideDisplay {
        extenderProvideGuess ?? ExtenderProvideDisplay.of(status: extenderProvideStatus)
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
    private var closeDeviceJwtRefreshListener: (() -> Void)?
    private var closeDeviceAuthLogoutListener: (() -> Void)?
    private var deviceCanShowRatingDialogSub: SdkSubProtocol?
    private var deviceCanPromptIntroFunnelSub: SdkSubProtocol?
    private var deviceAllowForegroundSub: SdkSubProtocol?
    private var deviceCanReferSub: SdkSubProtocol?
    private var deviceProvideModeSub: SdkSubProtocol?
    private var deviceProvideNetworkModeSub: SdkSubProtocol?
    private var deviceVpnInterfaceWhileOfflineSub: SdkSubProtocol?
    private var deviceDefaultLocationSub: SdkSubProtocol?
    private var deviceBlockerEnabledSub: SdkSubProtocol?
    private var extenderProvideSource: ExtenderProvideSource?
    private var extenderProvideCallbackOwner: ExtenderProvideCallbackOwner?
    private var closeExtenderProvideStatusListener: (() -> Void)?

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
    
    /// A sign-out's teardown (`device` nil) or a sign-in's new device. The
    /// device going away closes off the main actor (closeOffMainActor), as
    /// the quit's does: the sdk's DeviceRemote.Close takes the device's state
    /// lock, which a connect or disconnect command still in the sdk keeps
    /// through its rpc to the extension, up to the 60 s rpc timeout, and it
    /// closes every controller still open on the device, each with an rpc of
    /// its own.
    func setDevice(device: SdkDeviceRemote?) {
        guard device == nil || !isLoggingOut else {
            Self.closeOffMainActor(device)
            return
        }

        if self.device != device {

            cleanupDeviceListeners()
            self.vpnManager?.close()
            self.vpnManager = nil

            Self.closeOffMainActor(self.device)
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
                if startupMode.allowsVPNProfileSystemAccess {
                    vpnManagerInitializationInvocationCount += 1
                    self.vpnManager = VPNManager(device: device)
                }
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
        retireDeviceAuthCallbacks()
        setDevice(device: nil)
    }
    
    @Published private(set) var deviceInitialized: Bool = false
    
    private func handleProvideExtenderUpdate(_ provideExtender: Bool) {
        // the switch exists only while the device reports the role supported,
        // and a setting the device cannot take is never written (N1)
        guard extenderProvideStatus.supported, let source = extenderProvideSource else {
            return
        }
        extenderProvideGuess = ExtenderProvideDisplay.guess(
            on: provideExtender,
            providing: provideEnabled
        )
        source.writeProvideExtender(provideExtender)
    }

    private func handleMeasurementsEnabledUpdate(_ measurementsEnabled: Bool) {
        // the switch shows beside the Extender row, so only while the device
        // reports the role supported; a setting it cannot take is never written
        guard extenderProvideStatus.supported, let source = extenderProvideSource else {
            return
        }
        source.writeMeasurementsEnabled(measurementsEnabled)
    }

    /// One status from the source (N7), with the setting read beside it only
    /// while the status reports the role supported: a hidden row reads no
    /// setting, and the switch keeps its value meanwhile.
    private func applyExtenderProvideStatus(
        _ status: ExtenderProvideStatusModel,
        from source: ExtenderProvideSource
    ) {
        applyExtenderProvideStatus(
            status,
            provideExtender: status.supported ? source.readProvideExtender() : nil,
            measurementsEnabled: status.supported ? source.readMeasurementsEnabled() : nil
        )
    }

    /// One pushed, seeded or reset provider extender status (N7). It replaces
    /// the toggle's guess, and the switch takes the setting when one was read,
    /// under the echo guard so the read is not written back.
    private func applyExtenderProvideStatus(
        _ status: ExtenderProvideStatusModel,
        provideExtender: Bool?,
        measurementsEnabled: Bool?
    ) {
        if extenderProvideGuess != nil {
            extenderProvideGuess = nil
        }
        if extenderProvideStatus != status {
            extenderProvideStatus = status
        }
        if let provideExtender, self.provideExtender != provideExtender {
            withDeviceStateLoad {
                self.provideExtender = provideExtender
            }
        }
        if let measurementsEnabled, self.measurementsEnabled != measurementsEnabled {
            withDeviceStateLoad {
                self.measurementsEnabled = measurementsEnabled
            }
        }
    }

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
    
    init(
        startupMode: AppStartupMode = HardwareNoVPNLaunchContract.current,
        automaticallyInitialize: Bool = true,
        scheduleStartupInitialization: @MainActor (DeviceManager) -> Void = { manager in
            manager.scheduleNetworkSpaceInitialization()
        },
        authCallbackDispatch: @escaping DeviceAuthCallbackDispatch = { work in
            DispatchQueue.main.async { work() }
        },
        authCallbackEffects: DeviceAuthCallbackEffects = .live,
        extenderProvideCallbackDispatch: @escaping DeviceAuthCallbackDispatch = { work in
            DispatchQueue.main.async { work() }
        },
        logoutEffects: DeviceLogoutEffects = .live
    ) {
        self.startupMode = startupMode
        self.authCallbackDispatch = authCallbackDispatch
        self.authCallbackEffects = authCallbackEffects
        self.extenderProvideCallbackDispatch = extenderProvideCallbackDispatch
        self.logoutEffects = logoutEffects

        // This constructor-only opt-out permits memory tests. NetworkApp
        // supplies it only when it hosts unit tests: both production and
        // hardwareNoVPN retain normal startup.
        guard automaticallyInitialize else { return }
        let initializationScheduled = AppStartupInitializationGate.performIfAllowed(
            mode: startupMode
        ) {
            self.startupInitializationInvocationCount += 1
            scheduleStartupInitialization(self)
        }
        if !initializationScheduled {
            // Test-only startup owns a dedicated UI and must not leave
            // background handlers waiting for production initialization.
            self.deviceInitialized = true
            self.storedAuthenticationStartupState = .settled
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
    
    /// "Send feedback with logs": the extension uploads while the device rpc
    /// reaches it, else this process does (FeedbackLogUpload). Either one
    /// reads the log files from disk before it returns, so this runs off the
    /// main actor.
    func uploadLogs(feedbackId: String) {
        let steps = FeedbackLogUpload.Steps.live(device: device, api: api)
        Task.detached(priority: .utility) {
            let outcome = await FeedbackLogUpload.upload(feedbackId: feedbackId, steps: steps)
            print("[FeedbackLogUpload]\(outcome)")
        }
    }
    
    
    /// The quit's teardown: the device closes, the vpn profiles go, and
    /// `completion` reports the profiles. The device closes off the main
    /// actor (closeOffMainActor), so the quit's answer and its cap, which
    /// run there, never wait on it (QuitSequence).
    func closeOnQuit(completion: @escaping (Error?) -> Void) {
        retireNetworkLoginRequests()
        networkClientAuthenticationOwner = nil
        retireStoredAuthenticationStartup()
        retireDeviceAuthCallbacks()
        Self.closeOffMainActor(self.device)
        
        if let vpnManager = self.vpnManager {
            vpnManager.stopVpnTunnelOnQuit(completion: completion)
        } else {
            completion(nil)
        }
    }
    
}

extension DeviceManager {
    /// Producer admission happens before auth/network/browser work starts.
    func beginNetworkLoginRequest(origin: NetworkLoginOrigin) -> NetworkLoginRequest? {
        guard !isLoggingOut, networkLoginOrigin === origin, let networkSpace, let api else { return nil }
        let request = NetworkLoginRequest(origin: origin, networkSpace: networkSpace, api: api, manager: self)
        pendingNetworkLoginRequest = request
        return request
    }

    func isCurrentNetworkLoginRequest(_ request: NetworkLoginRequest) -> Bool {
        guard !isLoggingOut, networkSpace === request.networkSpace else { return false }
        if request.accepted { return acceptedNetworkLoginRequest === request }
        return networkLoginOrigin === request.origin && pendingNetworkLoginRequest === request
    }

    private func retireNetworkLoginRequests() {
        pendingNetworkLoginRequest = nil
        acceptedNetworkLoginRequest = nil
        networkLoginOrigin = NetworkLoginOrigin()
    }

    /// Consume the exact outer request once before any admin install or UI effect.
    func authenticateNetworkClient(
        _ login: NetworkLogin,
        request: NetworkLoginRequest,
        requestClient: ((SdkApi, SdkAuthNetworkClientArgs, SdkAuthNetworkClientCallbackProtocol) -> Void)? = nil,
        initializeDevice: ((String, String) -> Bool)? = nil,
        accepted: (() -> Void)? = nil
    ) async -> Result<Void, Error> {
        guard isCurrentNetworkLoginRequest(request), !request.registrationStarted else {
            return .failure(CancellationError())
        }
        request.registrationStarted = true
        return await authenticateNetworkClient(login.jwt, newNetwork: login.newNetwork, requestClient: requestClient, initializeDevice: initializeDevice, outerRequest: request, accepted: accepted)
    }
    /// Closes `device` on `queue`, never on the caller's thread: the quit's
    /// and every sign-out's and sign-in's (setDevice). The sdk's
    /// DeviceRemote.Close takes the device's state lock, which a connect
    /// command inside an rpc to the tunnel extension holds for up to the
    /// 60 s rpc timeout.
    nonisolated static func closeOffMainActor(
        _ device: SdkDeviceRemote?,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        guard let device else {
            return
        }
        let close = DeviceCloseWork(device: device)
        queue.async {
            close.run()
        }
    }
}

/// A device to close, handed to another queue. Unchecked: the device is a
/// gomobile proxy that may be called from any thread.
private struct DeviceCloseWork: @unchecked Sendable {
    let device: SdkDeviceRemote

    func run() {
        device.close()
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
        // A failed constructor during startup has not settled authentication.
        // Never emit even an intermediate completion to initialization waiters.
        self.deviceInitialized = storedAuthenticationStartupState == .settled
        self.updateParsedJwt()
    }

    /// A new login, logout or space owns authentication before any old callback.
    private func retireStoredAuthenticationStartup() {
        storedAuthenticationStartupOwner = nil
        storedAuthenticationStartupState = .settled
    }

    private func failStoredAuthenticationStartup() {
        storedAuthenticationStartupOwner = nil
        storedAuthenticationStartupState = .retryableFailure
        deviceInitialized = false
    }

    /// Retry the selected store, preparing the space again only if it was unavailable.
    func retryStoredAuthenticationStartup(
        dispatchPreparation: (@escaping @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        },
        prepareNetworkSpace: @escaping @MainActor (DeviceManager) -> Void = { $0.initializeNetworkSpace() }
    ) {
        guard storedAuthenticationStartupState == .retryableFailure else { return }
        storedAuthenticationStartupState = .loading
        if networkSpace == nil {
            scheduleNetworkSpaceInitialization(dispatch: dispatchPreparation, prepare: prepareNetworkSpace)
        } else {
            initializeStoredAuthentication()
        }
    }

    /// Own preparation before enqueueing it; a logout also retires work not yet started.
    func scheduleNetworkSpaceInitialization(
        dispatch: (@escaping @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        },
        prepare: @escaping @MainActor (DeviceManager) -> Void = { $0.initializeNetworkSpace() }
    ) {
        guard !isLoggingOut else { return }
        let owner = StoredAuthenticationStartupOwner()
        storedAuthenticationStartupOwner = owner
        storedAuthenticationStartupState = .loading
        deviceInitialized = false
        dispatch { [weak self] in
            guard let self, self.storedAuthenticationStartupOwner === owner,
                  !owner.completed else { return }
            owner.completed = true
            prepare(self)
        }
    }

    /// A checked empty store permits sign-in; unavailable storage preserves the session.
    /// Only bootstrap and construction are replaceable so tests can avoid native profiles/RPC.
    func initializeStoredAuthentication(
        loadActiveInstanceId: ((@escaping (String?) -> Void) -> Void)? = nil,
        initializeDevice: ((String, String) -> Bool)? = nil
    ) {
        guard !isLoggingOut else { return }
        let owner = StoredAuthenticationStartupOwner()
        storedAuthenticationStartupOwner = owner
        storedAuthenticationStartupState = .loading
        deviceInitialized = false
        guard let networkSpace, let localState = asyncLocalState?.getLocalState() else {
            failStoredAuthenticationStartup()
            return
        }

        let clientJwt: String
        let authEmpty: Bool
        do {
            let snapshot = try localState.getAuthStateSnapshot()
            clientJwt = snapshot.getByClientJwt()
            authEmpty = snapshot.getEmpty()
        } catch {
            failStoredAuthenticationStartup()
            return
        }
        if authEmpty {
            retireStoredAuthenticationStartup()
            markInitializedWithoutDevice()
            return
        }
        guard !clientJwt.isEmpty else {
            failStoredAuthenticationStartup()
            return
        }

        initDeviceFromStoredAuthentication(
            clientJwt: clientJwt,
            deviceSpec: getDeviceSpecs(),
            owner: owner,
            networkSpace: networkSpace,
            loadActiveInstanceId: loadActiveInstanceId,
            initializeDevice: initializeDevice
        )
    }
    
    private func initializeNetworkSpace() {
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                   in: .userDomainMask)[0]
        let storagePath = documentsPath.path()
        
        // The app process keeps its own extender directory for api dials but
        // opens the shared `.extenders` store read-only, so only the tunnel
        // extension ever writes it (EXTENDER.md K5). Set before the manager is
        // built, since a space opens its store at construction.
        URnetworkSdk.SdkSetExtenderStoreReadOnly(true)
        let networkSpaceManager = URnetworkSdk.SdkNewNetworkSpaceManager(storagePath)
        self.networkSpaceManager = networkSpaceManager
        
        // Migration of the legacy bundled key, creation of the bundled space and
        // the choice of which space to bind, in that order (see
        // `NetworkSpaceStartup`). No space object is held before this returns.
        setActiveNetworkSpace(networkSpaceManager.flatMap(NetworkSpaceStartup.prepareBundledNetworkSpace))
        
        initializeStoredAuthentication()
        
    }
    
}

// MARK: Network server selection
@MainActor
extension DeviceManager {

    // All accepted network-space assignments share the callback-retirement
    // boundary, including an unavailable space during initialization.
    func setActiveNetworkSpace(_ networkSpace: SdkNetworkSpace?) {
        self.networkSpace = networkSpace
    }

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
                values.migrationHostName = ""
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
        setActiveNetworkSpace(updated)
        return true
    }
}

// MARK: Device handlers
@MainActor
extension DeviceManager {
    private func initDeviceFromStoredAuthentication(
        clientJwt: String,
        deviceSpec: String,
        owner: StoredAuthenticationStartupOwner,
        networkSpace: SdkNetworkSpace,
        loadActiveInstanceId: ((@escaping (String?) -> Void) -> Void)?,
        initializeDevice: ((String, String) -> Bool)?
    ) {
        let finishInitialization = { [weak self] (activeInstanceId: String?) in
            guard let self, self.storedAuthenticationStartupOwner === owner,
                  self.networkSpace === networkSpace, !owner.completed else { return }
            owner.completed = true

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

            let initialized = initializeDevice?(clientJwt, deviceSpec)
                ?? self.initDevice(clientJwt: clientJwt, deviceSpec: deviceSpec)
            guard self.storedAuthenticationStartupOwner === owner else { return }
            if initialized {
                self.retireStoredAuthenticationStartup()
            } else {
                self.failStoredAuthenticationStartup()
            }
        }

        if let loadActiveInstanceId {
            loadActiveInstanceId(finishInitialization)
            return
        }

        // Hardware UI acceptance exercises normal API/authentication startup,
        // but never consults an installed profile or the tunnel RPC bootstrap.
        guard startupMode.allowsVPNProfileSystemAccess else {
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
        guard !isLoggingOut else { return false }
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

        var instanceId: SdkId?
        do {
            let snapshot = try localState.getAuthStateSnapshot()
            instanceId = snapshot.getInstanceId()
            if instanceId == nil {
                instanceId = SdkNewId()
                try localState.setInstanceId(instanceId)
            }
        } catch {
            print("[DeviceManager] stage=auth-observation result=failed")
            markInitializedWithoutDevice()
            return false
        }

        var newDeviceError: NSError?

        let device = SdkNewDeviceRemoteWithDefaults(
            networkSpace,
            clientJwt,
            instanceId,
            &newDeviceError
        )

        if let error = newDeviceError {
            device?.close()
            print("Error occurred: \(error.localizedDescription)")
            markInitializedWithoutDevice()
            return false
        } else {
            print("Device created successfully")
        }

        guard let device = device else {
            markInitializedWithoutDevice()
            return false
        }

        // Shared intent is admitted only after the SDK has accepted this
        // device-owned client. Failed checked reads never queue a nil location
        // into the extension and erase its surviving destination.
        if startupMode.allowsVPNProfileSystemAccess {
            TunnelIntentAdoption.adoptPending(localState: localState, device: device)
        }
        let connectLocation: SdkConnectLocation?
        let defaultLocation: SdkConnectLocation?
        do {
            connectLocation = try localState.readConnectLocation().getLocation()
            defaultLocation = try localState.readDefaultLocation().getLocation()
        } catch {
            device.close()
            print("[DeviceManager] stage=destination-observation result=failed")
            markInitializedWithoutDevice()
            return false
        }

        // Populate the shared restart credential on every authenticated cold
        // launch, not only when this build observes the next JWT rotation. For
        // upgraded installations the bootstrap above has already restored the
        // running profile's exact instance into LocalState, so this also closes
        // the one-restart migration gap for a token refreshed by an older build.
        // Use the successfully published device client, not the preliminary
        // input or the shared API slot an admin login can own.
        if startupMode.allowsVPNProfileSystemAccess {
            VPNManager.seedCurrentTunnelJwtIfMissing(device: device)
        }

        // point the rpc transport at the last known good session (if any) so the
        // device can connect to an already-running extension immediately, instead
        // of the default 127.0.0.1:12025 ws until the vpn is (re)started
        if startupMode.allowsVPNProfileSystemAccess,
           let rpcSession = RpcSessionStore.loadResult().session {
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

        // split rules ("block action overrides") cross the same way, mirrored
        // by BlockActionsStore. One consequence beyond the transport settings
        // above: without the seed the remote rebuilds its "full" list from
        // nothing, so an edit made while the tunnel was down does not merely
        // fail to save -- it replaces the extension's saved rules on the next
        // connect. Nothing stored means never edited, and a store that cannot
        // be read reports the same way, so both leave the extension's rules
        // alone; an empty list is a real value -- the last rule was deleted --
        // and is seeded as one. This must stay above setDevice, which is what
        // publishes the device and drives BlockActionsStore.setup.
        if let blockActionOverrides = localState.getBlockActionOverrides() {
            device.setBlockActionOverrides(blockActionOverrides)
        }

        // the dns resolver settings cross the same way, mirrored by
        // DnsSettingsStore. The editor opens on whatever the device reports, so
        // without the seed a tunnel-down launch shows the blank
        // never-configured form over the resolver the extension has on disk,
        // and applying an edit from that blank base replaces it on the next
        // connect. Nothing stored means never mirrored -- leave the
        // extension's resolver alone; settings with everything turned off are
        // a real value and are seeded as one. Above setDevice for the same
        // reason as the rules.
        if let dnsResolverSettings = localState.getDnsResolverSettings() {
            device.setDnsResolverSettings(dnsResolverSettings)
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
                if self.providePaused != providePaused {
                    self.providePaused = providePaused
                }
            }
        })
        
        self.deviceProvideSub = device.add(ProvideChangeListener { [weak self] provideEnabled in
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                if self.provideEnabled != provideEnabled {
                    self.provideEnabled = provideEnabled
                }
            }
        })
        
        // the provider extender status and setting (N2, N7), beside the
        // provide listeners: the listener, then the seed
        setupExtenderProvide(source: device)

        setupDeviceAuthListeners(source: device)

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
                if self?.currentProvideMode != provideMode {
                    self?.currentProvideMode = provideMode
                }
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

    // Registration and delivery are separate boundaries: removing an SDK
    // listener cannot recall work already queued on the main actor.
    func setupDeviceAuthListeners(source: DeviceAuthCallbackSource) {
        cleanupDeviceAuthListeners()
        let owner = DeviceAuthCallbackOwner()
        deviceAuthCallbackOwner = owner
        let instanceId = source.authCallbackInstanceId()
        let dispatch = authCallbackDispatch

        closeDeviceJwtRefreshListener = source.observeAuthRefresh { [weak self] jwt in
            dispatch { [weak self] in
                guard let self, self.deviceAuthCallbackOwner === owner else { return }
                self.updateParsedJwt()
                guard self.startupMode.allowsVPNProfileSystemAccess else { return }
                guard let jwt, !jwt.isEmpty,
                      let instanceId, !instanceId.isEmpty else { return }
                self.authCallbackEffects.persistRefresh(jwt, instanceId)
            }
        }
        closeDeviceAuthLogoutListener = source.observeAuthLogout { [weak self] cause in
            dispatch { [weak self] in
                guard let self, self.deviceAuthCallbackOwner === owner else { return }
                self.retireDeviceAuthCallbacks()
                // the sign-in screen says why, when the server said so
                self.signedOutNotice = SignedOutNotice(authLogoutCause: cause)
                self.authCallbackEffects.logout(self)
            }
        }
    }

    // An accepted explicit login owns auth before its replacement remote is
    // ready. A pending request or failed write must leave serving auth alone.
    @discardableResult
    func acceptNetworkLogin(_ commitAdmin: () throws -> Void) rethrows -> Bool {
        guard !isLoggingOut else { return false }
        try commitAdmin()
        retireNetworkLoginRequests()
        networkClientAuthenticationOwner = nil
        retireStoredAuthenticationStartup()
        retireDeviceAuthCallbacks()
        // a notice belongs to the signed-out stretch this login ends
        signedOutNotice = nil
        return true
    }

    /// The sign-in screen showed the notice and the user dismissed it.
    func dismissSignedOutNotice() {
        signedOutNotice = nil
    }

    func retireDeviceAuthCallbacks() {
        deviceAuthCallbackOwner = nil
    }

    // The provider extender status and setting of one device (EXTENDER.md
    // N7): the listener, then the seed, since the listener reports only
    // changes. As for the auth callbacks, registration and delivery are
    // separate boundaries: a status still queued from a replaced source is
    // dropped.
    func setupExtenderProvide(source: ExtenderProvideSource) {
        resetExtenderProvide()
        let owner = ExtenderProvideCallbackOwner()
        extenderProvideCallbackOwner = owner
        extenderProvideSource = source
        let dispatch = extenderProvideCallbackDispatch
        closeExtenderProvideStatusListener = source.observeExtenderProvideStatus { [weak self] status in
            dispatch { [weak self] in
                guard let self, self.extenderProvideCallbackOwner === owner,
                      let source = self.extenderProvideSource else { return }
                self.applyExtenderProvideStatus(status, from: source)
            }
        }
        applyExtenderProvideStatus(source.readExtenderProvideStatus(), from: source)
    }

    // The status and the setting reset with the device (N7) under the echo
    // guard, so nothing is written, and a toggle afterwards reaches no device.
    func resetExtenderProvide() {
        extenderProvideCallbackOwner = nil
        closeExtenderProvideStatusListener?()
        closeExtenderProvideStatusListener = nil
        extenderProvideSource = nil
        applyExtenderProvideStatus(.unsupported, provideExtender: true, measurementsEnabled: true)
    }

    private func cleanupDeviceAuthListeners() {
        retireDeviceAuthCallbacks()
        closeDeviceJwtRefreshListener?()
        closeDeviceJwtRefreshListener = nil
        closeDeviceAuthLogoutListener?()
        closeDeviceAuthLogoutListener = nil
    }

    private func cleanupDeviceListeners() {
        cleanupDeviceAuthListeners()
        deviceProvideSub?.close()
        deviceProvideSub = nil
        
        deviceProvidePausedSub?.close()
        deviceProvidePausedSub = nil
        
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

        // the extender status and setting reset with the device (N7)
        resetExtenderProvide()
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
    // Native deliveries are admitted once on the same queue that resumes the task.
    private var completed = false

    func result(_ result: SdkAuthNetworkClientResult?, err: Error?) {
        
        DispatchQueue.main.async {
            guard !self.completed else { return }
            self.completed = true
            self.handleResult(result, err: err)
        }
    }
}

// MARK: login/logout
@MainActor
extension DeviceManager {
    
    /**
     * Signs the network in. The post-login onboarding flow is for a network
     * that was just created (`newNetwork`), never for an existing account
     * signing in: the SDK reads a missing flag as "may prompt", so the flag is
     * written explicitly on every login, before the device reads it.
     */
    func authenticateNetworkClient(
        _ jwt: String,
        newNetwork: Bool = false,
        requestClient: ((SdkApi, SdkAuthNetworkClientArgs, SdkAuthNetworkClientCallbackProtocol) -> Void)? = nil,
        initializeDevice: ((String, String) -> Bool)? = nil,
        outerRequest: NetworkLoginRequest? = nil,
        accepted: (() -> Void)? = nil
    ) async -> Result<Void, Error> {
        guard !isLoggingOut else { return .failure(CancellationError()) }
        if let outerRequest, !isCurrentNetworkLoginRequest(outerRequest) { return .failure(CancellationError()) }
        guard let networkSpace, let localState = asyncLocalState?.getLocalState(), let api else {
            return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "login: state is unavailable"]))
        }

        let owner = NetworkClientAuthenticationOwner(networkSpace: networkSpace, localState: localState, api: api)
        do {
            guard try acceptNetworkLogin({ try localState.setByJwt(jwt) }) else {
                return .failure(CancellationError())
            }
            networkClientAuthenticationOwner = owner
            if let outerRequest {
                outerRequest.accepted = true
                acceptedNetworkLoginRequest = outerRequest
            }
            try localState.setCanPromptIntroFunnel(newNetwork)
        } catch {
            return .failure(error)
        }
        api.setByJwt(jwt)
        accepted?()

        do {
            let deviceSpecs = getDeviceSpecs()
            let clientJwt: String = try await withCheckedThrowingContinuation { continuation in
                let authArgs = SdkAuthNetworkClientArgs()
                authArgs.deviceDescription = deviceDescription
                authArgs.deviceSpec = deviceSpecs
                Self.applyClientContext(to: authArgs)
                let callback = AuthNetworkClientCallback { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let resultError = result?.error {
                        continuation.resume(throwing: NSError(domain: "DeviceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                    } else if let clientJwt = result?.byClientJwt, !clientJwt.isEmpty {
                        continuation.resume(returning: clientJwt)
                    } else {
                        continuation.resume(throwing: NSError(domain: "DeviceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Auth network client returned no client JWT"]))
                    }
                }
                if let requestClient {
                    requestClient(api, authArgs, callback)
                } else {
                    api.authNetworkClient(authArgs, callback: callback)
                }
            }

            guard ownsNetworkClientAuthentication(owner) else { throw CancellationError() }
            // Commit and construct on this admitted actor turn. An async storage
            // write would outlive its admission and could overwrite a later login.
            try owner.localState.setByClientJwt(clientJwt)
            guard initializeDevice?(clientJwt, deviceSpecs)
                    ?? initDevice(clientJwt: clientJwt, deviceSpec: deviceSpecs) else {
                throw NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize device"])
            }
            networkClientAuthenticationOwner = nil
            return .success(())
        } catch {
            rollbackFailedNetworkClientAuthentication(owner)
            return .failure(error)
        }
    }

    private func ownsNetworkClientAuthentication(_ owner: NetworkClientAuthenticationOwner) -> Bool {
        !isLoggingOut && networkClientAuthenticationOwner === owner && networkSpace === owner.networkSpace
    }

    /**
     * Records that the post-signup introduction finished or was skipped. The
     * flag is written to the local state directly and pushed to the device, so
     * a rebuilt view or a later launch never prompts again for this network.
     */
    func completeIntroFunnel() {
        try? asyncLocalState?.getLocalState()?.setCanPromptIntroFunnel(false)
        device?.setCanPromptIntroFunnel(false)
    }

    private func rollbackFailedNetworkClientAuthentication(_ owner: NetworkClientAuthenticationOwner) {
        guard ownsNetworkClientAuthentication(owner) else { return }
        networkClientAuthenticationOwner = nil
        owner.api.setByJwt(nil)
        do {
            // Keep both writes on the admitted main-actor turn; no queued rollback
            // may run after a replacement's synchronous admin install.
            try owner.localState.setByJwt(nil)
            try owner.localState.setByClientJwt(nil)
        } catch {
            print("[authenticateNetworkClient] failed to roll back authentication")
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
    
    // Admission captures the original resources before observers can change space.
    func beginLogout() -> Bool {
        guard !isLoggingOut else { return false }
        let owner = DeviceLogoutOwner(manager: self)
        logoutOwner = owner
        isLoggingOut = true
        networkClientAuthenticationOwner = nil
        retireNetworkLoginRequests()
        retireStoredAuthenticationStartup()
        retireDeviceAuthCallbacks()
        if let device = owner.device { logoutStarted?(device) }
        return true
    }

    func logout() {
        guard beginLogout(), let owner = logoutOwner else { return }
        owner.api?.setByJwt(nil)
        guard startupMode.allowsVPNProfileSystemAccess else {
            completeLogoutProfiles(owner, error: nil)
            return
        }
        logoutEffects.clearTunnelCredential()
        let dispatch = authCallbackDispatch
        logoutEffects.removeProfiles(owner.vpnManager) { error in
            dispatch { self.completeLogoutProfiles(owner, error: error) }
        }
    }

    private func completeLogoutProfiles(_ owner: DeviceLogoutOwner, error: Error?) {
        guard logoutOwner === owner, !owner.profilesCompleted else { return }
        owner.profilesCompleted = true
        owner.profilesSucceeded = error == nil
        if error != nil {
            // A deadline is not a join of OS work. Retain the admission fence
            // after failure, even while clearing the signed-out local account.
            print("[logout] profile cleanup unresolved; login remains blocked")
        }
        owner.vpnManager?.close()
        if vpnManager === owner.vpnManager { vpnManager = nil }
        guard let localState = owner.localState else {
            completeLogoutLocalState(owner, success: true)
            return
        }
        let dispatch = authCallbackDispatch
        let callback = SdkCommitCallback { success in
            dispatch { self.completeLogoutLocalState(owner, success: success) }
        }
        logoutEffects.clearLocalState(localState, callback)
    }

    private func completeLogoutLocalState(_ owner: DeviceLogoutOwner, success: Bool) {
        guard logoutOwner === owner, !owner.localStateCompleted else { return }
        owner.localStateCompleted = true
        if !success { print("[logout] asyncLocalState logout failed") }
        if networkSpace === owner.networkSpace, device === owner.device { clearDevice() }
        guard owner.profilesSucceeded else { return }
        logoutOwner = nil
        isLoggingOut = false
    }

    // concise, human-readable spec shown in the peers list:
    // "<os> <retail model>", e.g. "18.5 iPhone 16 Pro Max",
    // "15.5 MacBook Pro (16-inch, Nov 2023)". `UIDevice.model` is just
    // "iPhone", and `UIDevice.name` has been the generic "iPhone" since
    // iOS 16 — the old spec read "iPhone iPhone". The retail name comes
    // from the hardware identifier via the bundled `DeviceModelNames`
    // table; unknown (newer) identifiers fall back to the identifier
    // itself ("iPhone19,1"), which still names the device
    /// The device's time zone (IANA) and locale (BCP 47) go with every
    /// auth-client call: the server schedules onboarding sends in local time
    /// and picks the template language from them. The SDK's args gain the two
    /// fields with the onboarding SDK rebuild; until the linked xcframework has
    /// them they are set through key-value coding only when the properties
    /// exist, so the app builds and runs against either framework.
    static func applyClientContext(to authArgs: SdkAuthNetworkClientArgs) {
        let context: [(selector: String, key: String, value: String)] = [
            ("setTimeZone:", "timeZone", TimeZone.current.identifier),
            ("setLocale:", "locale", Locale.current.identifier(.bcp47)),
        ]
        for entry in context where authArgs.responds(to: Selector(entry.selector)) {
            authArgs.setValue(entry.value, forKey: entry.key)
        }
    }

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

private class ExtenderProvideStatusChangeListener: NSObject, SdkExtenderProvideStatusChangeListenerProtocol {

    private let c: (_ status: SdkExtenderProvideStatus?) -> Void

    init(c: @escaping (_ status: SdkExtenderProvideStatus?) -> Void) {
        self.c = c
    }

    func extenderProvideStatusChanged(_ status: SdkExtenderProvideStatus?) {
        c(status)
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
