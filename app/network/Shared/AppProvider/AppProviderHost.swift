//
//  AppProviderHost.swift
//  URnetwork
//
//  macOS: the app runs the provider while the VPN is off, and hands it to the
//  packet tunnel when the VPN connects and back when it disconnects (owner,
//  2026-11-28, apple#174). The sdk owns the decisions and the one client per
//  install guarantee (SdkAppProvider, sdk/docs/MACOS-APP-PROVIDER.md); this is
//  the platform half. It keeps the provider's inputs current: the signed in
//  client, the device rpc the app's DeviceRemote dials, the provide mode, the
//  VPN status and whether the VPN manager wants the tunnel, and the provide
//  pause the extension decides for itself from the network path and the power
//  state. It registers the login item once the user provides, keeps the app
//  awake to the system while it provides, and adopts the identity the tunnel
//  presents once per tunnel session.
//
//  Only the main app's DeviceManager owns one (NetworkApp); the intents and
//  previews that build their own DeviceManager do not provide. Main actor only.
//

#if os(macOS)
import Foundation
import Network
import NetworkExtension
import ServiceManagement
import URnetworkSdk

@MainActor
final class AppProviderHost {

    /// The tunnel answers this provider message with the identity it presents
    /// (SdkExportClientIdentityJson), which the app adopts.
    static let clientIdentityProviderMessage = "client-identity"
    /// The profile key the tunnel imports the app's identity from.
    static let clientIdentityConfigurationKey = "client_identity"
    /// Whether the app has registered its login item before: from then on the
    /// user's own choice stands (SdkAppProviderShouldRegisterLoginItem).
    static let loginItemRegisteredKey = "network.ur.app-provider.login-item-registered"
    /// How long a stop of the tunnel waits for the tunnel's identity, when the
    /// app keeps none yet.
    static let identityBeforeStopTimeout: TimeInterval = 3

    private let provider: SdkAppProvider
    private let pathMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.loopback, .other])
    private let pathQueue = DispatchQueue(label: "network.ur.app-provider.path")
    private var path: NWPath?
    private let chargingMonitor = ProvideChargingMonitor()
    private var observers: [NSObjectProtocol] = []
    // retained so their connections keep posting NEVPNStatusDidChange
    private var observedManagers: [NETunnelProviderManager] = []
    private var statusSub: SdkSubProtocol?
    private var status: String = SdkAppProviderStatusOff
    // holds off App Nap and automatic termination while the app provides; the
    // system still sleeps when idle
    private var activity: NSObjectProtocol?

    init?() {
        let tier = Self.memoryTier()
        // the extension's pair (TunnelDeviceMemoryTarget.macosTier): the pools
        // and soft limit back the device's target twice over
        SdkSetMemoryLimit(tier.processBudgetByteCount)
        guard let storagePath = Self.storagePath(),
              let provider = SdkNewAppProvider(
                storagePath,
                SdkNewClientInfoWithDistribution(AppClientInfo.deviceType, AppClientInfo.bundleAppVersion, AppClientInfo.buildDistribution),
                "macos-app-provider",
                Self.deviceSpec(),
                AppClientInfo.bundleAppVersion,
                tier.deviceTargetByteCount
              ) else {
            return nil
        }
        self.provider = provider

        statusSub = provider.add(AppProviderStatusListener { [weak self] status in
            DispatchQueue.main.async {
                self?.statusChanged(status)
            }
        })

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.path = path
                self?.updateProvidePaused()
            }
        }
        pathMonitor.start(queue: pathQueue)
        chargingMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateProvidePaused()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProvidePaused()
            }
        })
        // the "When on battery" choice is saved in the app's defaults
        // (ProvidePowerStore)
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProvidePaused()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let session = notification.object as? NETunnelProviderSession
            Task { @MainActor [weak self] in
                self?.tunnelStatusChanged(session: session)
            }
        })
        // a profile the app installs or removes changes what runs
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTunnelStatus()
            }
        })
        updateProvidePaused()
        refreshTunnelStatus()
    }

    /// The quit: the device closes and the lease is let go (bounded by the
    /// sdk's close timeout). Off the main actor, as the quit's other closes.
    func close() {
        pathMonitor.cancel()
        chargingMonitor.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        observedManagers = []
        statusSub?.close()
        statusSub = nil
        endActivity()
        let provider = self.provider
        DispatchQueue.global(qos: .userInitiated).async {
            provider.close()
        }
    }

    // MARK: - Inputs

    /// The signed in client, or nil when there is none. The app calls this
    /// again after the client's credential refreshes.
    func setClient(device: SdkDeviceRemote?, networkSpace: SdkNetworkSpace?) {
        guard let device, let networkSpace,
              let instanceId = device.getInstanceId() else {
            provider.setIdentity("", byClientJwt: "", instanceId: nil)
            updateLoginItem()
            return
        }
        var err: NSError?
        let networkSpaceJson = networkSpace.toJson(&err)
        guard err == nil, !networkSpaceJson.isEmpty else {
            provider.setIdentity("", byClientJwt: "", instanceId: nil)
            return
        }
        provider.setIdentity(networkSpaceJson, byClientJwt: device.getClientJwt(), instanceId: instanceId)
        updateLoginItem()
    }

    /// Every sign-out: the device closes, the lease is let go, and the
    /// provider's own storage of the client is wiped.
    func signOut() {
        provider.signOut()
    }

    func setProvideControlMode(_ mode: ProvideControlMode) {
        provider.setProvideControlMode(mode.rawValue)
        updateLoginItem()
    }

    /// The device rpc the app's DeviceRemote dials: the provider serves it on
    /// the extension's address with the extension's certificates.
    func setRpcSession(_ session: RpcSession?) {
        guard let session else {
            provider.setRpcServer("", clientCertPem: "", hostPort: "")
            return
        }
        provider.setRpcServer(session.serverPem, clientCertPem: session.clientCertPem, hostPort: session.hostPort)
    }

    /// Whether the VPN manager wants the tunnel up. True gives the client up
    /// before the tunnel asks for it.
    func setTunnelWanted(_ wanted: Bool) {
        provider.setTunnelWanted(wanted)
    }

    /// The identity the tunnel profile carries; empty while the app keeps none.
    var clientIdentityJson: String {
        provider.getClientIdentityJson()
    }

    // MARK: - The tunnel

    private func tunnelStatusChanged(session: NETunnelProviderSession?) {
        refreshTunnelStatus()
        // a tunnel that connected is asked for the identity it presents, once
        // per connect: an install whose tunnel made its keys before the app
        // kept any keeps them, and a drifted identity converges
        if let session, session.status == .connected {
            fetchTunnelIdentity(session: session, completion: nil)
        }
    }

    /// Reads every profile's status into the provider: the most running one
    /// wins, and no profile at all is invalid.
    func refreshTunnelStatus() {
        VPNProfileSystem.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard error == nil else {
                    // unknown: the tunnel may be running
                    self.provider.setTunnelStatus(SdkAppProviderTunnelStatusUnknown)
                    return
                }
                let ownManagers = (managers ?? []).filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                        == TunnelProviderIdentity.bundleIdentifier
                }
                self.observedManagers = ownManagers
                self.provider.setTunnelStatus(Self.tunnelStatus(ownManagers.map { $0.connection.status }))
            }
        }
    }

    /// The sdk's status for a set of profile statuses.
    nonisolated static func tunnelStatus(_ statuses: [NEVPNStatus]) -> String {
        let order: [(NEVPNStatus, String)] = [
            (.connected, SdkAppProviderTunnelStatusConnected),
            (.reasserting, SdkAppProviderTunnelStatusReasserting),
            (.connecting, SdkAppProviderTunnelStatusConnecting),
            (.disconnecting, SdkAppProviderTunnelStatusDisconnecting),
            (.disconnected, SdkAppProviderTunnelStatusDisconnected),
        ]
        for (status, name) in order where statuses.contains(status) {
            return name
        }
        return SdkAppProviderTunnelStatusInvalid
    }

    /// Asks the running tunnel for the identity it presents and adopts it.
    /// `completion` runs once, on the main actor, when the answer is in or
    /// after identityBeforeStopTimeout.
    func fetchTunnelIdentity(session: NETunnelProviderSession, completion: (() -> Void)?) {
        var completed = false
        let complete = {
            guard !completed else { return }
            completed = true
            completion?()
        }
        if completion != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.identityBeforeStopTimeout) {
                MainActor.assumeIsolated { complete() }
            }
        }
        do {
            try session.sendProviderMessage(Data(Self.clientIdentityProviderMessage.utf8)) { [weak self] response in
                let identityJson = response.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !identityJson.isEmpty, identityJson != Self.clientIdentityProviderMessage {
                            do {
                                try self?.provider.adoptClientIdentityJson(identityJson)
                            } catch {
                                print("[AppProviderHost]tunnel identity not adopted: \(error.localizedDescription)")
                            }
                        }
                        complete()
                    }
                }
            }
        } catch {
            print("[AppProviderHost]tunnel identity request failed: \(error.localizedDescription)")
            complete()
        }
    }

    /// Before the VPN manager stops the tunnel: when the app keeps no identity
    /// yet and a tunnel runs, the tunnel's is asked for first, so the client
    /// the app runs next presents the keys the tunnel made. Once per install
    /// in practice (an update from a build that provided only in the tunnel).
    func beforeTunnelStop(completion: @escaping () -> Void) {
        let running = observedManagers
            .compactMap { $0.connection as? NETunnelProviderSession }
            .first { $0.status == .connected || $0.status == .reasserting }
        guard clientIdentityJson.isEmpty, let running else {
            completion()
            return
        }
        fetchTunnelIdentity(session: running, completion: completion)
    }

    // MARK: - Pause, login item and activity

    private func updateProvidePaused() {
        let networkCanProvide = path.map(Self.canProvideOnNetwork) ?? false
        let power = ProvidePowerState(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            charging: chargingMonitor.charging
        )
        let pauseReason = ProvidePausePolicy.pauseReason(
            networkCanProvide: networkCanProvide,
            power: power,
            mode: ProvidePowerModeStore.load()
        )
        provider.setProvidePaused(pauseReason != nil)
    }

    /// The extension's rule on a Mac (canProvideOnNetwork in
    /// PacketTunnelProvider.swift), so the provider pauses the same way in
    /// either process: never on a constrained path, on Wi-Fi or wired only
    /// when it is not expensive, and not before macOS 15.
    nonisolated static func canProvideOnNetwork(_ path: NWPath) -> Bool {
        guard #available(macOS 15, *) else {
            return false
        }
        if path.isConstrained {
            return false
        }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return !path.isExpensive
        }
        return false
    }

    private func statusChanged(_ status: String) {
        self.status = status
        switch status {
        case SdkAppProviderStatusWaiting, SdkAppProviderStatusStarting, SdkAppProviderStatusRunning:
            beginActivity()
        default:
            endActivity()
        }
        updateLoginItem()
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "URnetwork provides from this Mac"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// The app opens at login once the user provides from this Mac, the first
    /// time only: a login item the user turned off stays off.
    private func updateLoginItem() {
        let registeredBefore = UserDefaults.standard.bool(forKey: Self.loginItemRegisteredKey)
        guard SdkAppProviderShouldRegisterLoginItem(
            provider.getProvidesWhileVpnOff(),
            SMAppService.mainApp.status == .enabled,
            registeredBefore
        ) else {
            return
        }
        UserDefaults.standard.set(true, forKey: Self.loginItemRegisteredKey)
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("[AppProviderHost]login item not registered: \(error.localizedDescription)")
        }
    }

    /// The user set the login item themselves (Settings): the app never
    /// changes it from then on.
    static func userChoseLoginItem() {
        UserDefaults.standard.set(true, forKey: loginItemRegisteredKey)
    }

    // MARK: - Environment

    /// A directory of the app's own that only the provider uses, as the
    /// extension's documents directory is the extension's.
    private static func storagePath() -> String? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("URnetworkProvider", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[AppProviderHost]storage unavailable: \(error.localizedDescription)")
            return nil
        }
        return directory.path
    }

    /// The Mac's model, as the extension reports it (deviceModel()).
    private static func deviceSpec() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, 0 < size else {
            return "macos-unknown"
        }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "macos-unknown"
        }
        return String(cString: model)
    }

    struct MemoryTier: Equatable {
        let deviceTargetByteCount: Int64
        let processBudgetByteCount: Int64
    }

    /// The extension's macOS tier (TunnelDeviceMemoryTarget.macosTier in
    /// extension/TunnelMemoryBounds.swift, which the app target does not
    /// build): 128 MiB in a 384 MiB budget, and 256 MiB in 768 MiB on a Mac
    /// with more than 7 GiB. Keep the two equal.
    nonisolated static func memoryTier(hostMemoryByteCount: Int64? = hostMemoryByteCount()) -> MemoryTier {
        guard let hostMemoryByteCount, 7 * 1024 * 1024 * 1024 < hostMemoryByteCount else {
            return MemoryTier(deviceTargetByteCount: 128 * 1024 * 1024, processBudgetByteCount: 384 * 1024 * 1024)
        }
        return MemoryTier(deviceTargetByteCount: 256 * 1024 * 1024, processBudgetByteCount: 768 * 1024 * 1024)
    }

    nonisolated static func hostMemoryByteCount() -> Int64? {
        var byteCount: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname("hw.memsize", &byteCount, &size, nil, 0) == 0, 0 < byteCount else {
            return nil
        }
        return byteCount
    }
}

private final class AppProviderStatusListener: NSObject, SdkAppProviderStatusChangeListenerProtocol {
    private let c: (String) -> Void

    init(c: @escaping (String) -> Void) {
        self.c = c
    }

    func appProviderStatusChanged(_ status: String?) {
        c(status ?? SdkAppProviderStatusOff)
    }
}
#endif
