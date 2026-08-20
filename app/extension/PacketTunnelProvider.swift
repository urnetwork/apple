//
//  PacketTunnelProvider.swift
//  network
//
//  Created by Stuart Kuentzel on 2024/12/24.
//

import NetworkExtension
import URnetworkExtensionSdk
import OSLog
import Security
import CryptoKit

//import Atomics

private struct TunnelNetworkSettingsPlan {
    let settings: NEPacketTunnelNetworkSettings
    let signature: String
}

private struct SharedTunnelJwtEnvelope: Codable {
    static let currentVersion = 2
    let version: Int
    let instanceId: String
    let byJwt: String
    let issuedAt: Int64?
    let expiresAt: Int64?

    init(
        instanceId: String,
        byJwt: String,
        issuedAt: Int64?,
        expiresAt: Int64?
    ) {
        self.version = Self.currentVersion
        self.instanceId = instanceId
        self.byJwt = byJwt
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

private struct LegacySharedTunnelJwtEnvelope: Codable {
    let version: Int
    let instanceId: String
    let byJwt: String
}

private struct SharedTunnelJwtCandidate {
    let account: String
    let byJwt: String
    let issuedAt: Int64?
    let expiresAt: Int64?
}

private enum SharedTunnelJwtStore {
    private static let service = "network.ur.shared-tunnel-jwt"
    private static let accountPrefix = "v2-"
    private static let retainedTokensPerInstance = 3

    static func load(expectedInstanceId: String) -> String? {
        freshest(loadCandidates(expectedInstanceId: expectedInstanceId))?.byJwt
    }

    @discardableResult
    static func save(byJwt: String, instanceId: String) -> Bool {
        let dates = jwtDates(byJwt)
        guard !byJwt.isEmpty, !instanceId.isEmpty,
              let account = account(byJwt: byJwt, instanceId: instanceId),
              let data = try? JSONEncoder().encode(
                SharedTunnelJwtEnvelope(
                    instanceId: instanceId,
                    byJwt: byJwt,
                    issuedAt: dates.issuedAt,
                    expiresAt: dates.expiresAt
                )
              ), var query = keychainIdentityQuery(account: account) else {
            return false
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            return false
        }
        prune(expectedInstanceId: instanceId)
        return true
    }

    static func clear() {
        guard let query = keychainIdentityQuery() else { return }
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func loadCandidates(
        expectedInstanceId: String
    ) -> [SharedTunnelJwtCandidate] {
        guard var query = keychainIdentityQuery() else { return [] }
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return []
        }
        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            return []
        }
        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data,
                  let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return candidate(
                data: data,
                account: account,
                expectedInstanceId: expectedInstanceId
            )
        }
    }

    private static func candidate(
        data: Data,
        account: String,
        expectedInstanceId: String
    ) -> SharedTunnelJwtCandidate? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(
            SharedTunnelJwtEnvelope.self,
            from: data
        ), envelope.version == SharedTunnelJwtEnvelope.currentVersion,
           envelope.instanceId == expectedInstanceId,
           !envelope.byJwt.isEmpty {
            return SharedTunnelJwtCandidate(
                account: account,
                byJwt: envelope.byJwt,
                issuedAt: envelope.issuedAt,
                expiresAt: envelope.expiresAt
            )
        }
        if let legacy = try? decoder.decode(
            LegacySharedTunnelJwtEnvelope.self,
            from: data
        ), legacy.version == 1,
           legacy.instanceId == expectedInstanceId,
           !legacy.byJwt.isEmpty {
            let dates = jwtDates(legacy.byJwt)
            return SharedTunnelJwtCandidate(
                account: account,
                byJwt: legacy.byJwt,
                issuedAt: dates.issuedAt,
                expiresAt: dates.expiresAt
            )
        }
        return nil
    }

    private static func freshest(
        _ candidates: [SharedTunnelJwtCandidate],
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> SharedTunnelJwtCandidate? {
        candidates.max { lhs, rhs in
            isPreferred(rhs, over: lhs, now: now)
        }
    }

    private static func isPreferred(
        _ lhs: SharedTunnelJwtCandidate,
        over rhs: SharedTunnelJwtCandidate,
        now: Int64
    ) -> Bool {
        let lhsExpired = lhs.expiresAt.map { $0 <= now } ?? false
        let rhsExpired = rhs.expiresAt.map { $0 <= now } ?? false
        if lhsExpired != rhsExpired { return !lhsExpired }
        let lhsIssuedAt = lhs.issuedAt ?? Int64.min
        let rhsIssuedAt = rhs.issuedAt ?? Int64.min
        if lhsIssuedAt != rhsIssuedAt { return lhsIssuedAt > rhsIssuedAt }
        let lhsExpiresAt = lhs.expiresAt ?? Int64.min
        let rhsExpiresAt = rhs.expiresAt ?? Int64.min
        if lhsExpiresAt != rhsExpiresAt { return lhsExpiresAt > rhsExpiresAt }
        return lhs.account > rhs.account
    }

    private static func prune(expectedInstanceId: String) {
        let candidates = loadCandidates(expectedInstanceId: expectedInstanceId)
        guard candidates.count > retainedTokensPerInstance else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let keep = Set(
            candidates.sorted { isPreferred($0, over: $1, now: now) }
                .prefix(retainedTokensPerInstance)
                .map(\.account)
        )
        for candidate in candidates where !keep.contains(candidate.account) {
            guard let query = keychainIdentityQuery(account: candidate.account) else {
                continue
            }
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    private static func jwtDates(
        _ jwt: String
    ) -> (issuedAt: Int64?, expiresAt: Int64?) {
        let components = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return (nil, nil) }
        var payload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else {
            return (nil, nil)
        }
        func int64(_ value: Any?) -> Int64? {
            if let number = value as? NSNumber { return number.int64Value }
            if let string = value as? String { return Int64(string) }
            return nil
        }
        return (int64(claims["iat"]), int64(claims["exp"]))
    }

    private static func account(byJwt: String, instanceId: String) -> String? {
        guard !byJwt.isEmpty, !instanceId.isEmpty else { return nil }
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
        }
        return accountPrefix + digest(instanceId) + "-" + digest(byJwt)
    }

    private static func keychainIdentityQuery(
        account: String? = nil
    ) -> [String: Any]? {
        guard let accessGroup = Bundle.main.object(
            forInfoDictionaryKey: "URSharedKeychainAccessGroup"
        ) as? String, !accessGroup.isEmpty else {
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}

// see https://developer.apple.com/documentation/networkextension/nepackettunnelprovider
// discussion on how the PacketTunnelProvider is excluded from the routes it sets up:
// see https://forums.developer.apple.com/forums/thread/677180
// note we do not use the df "ioloop" on ios - see https://developer.apple.com/forums/thread/13503
class PacketTunnelProvider: NEPacketTunnelProvider {

    /**
     * Print does not work for logging with extensions in XCode.
     * You can open up the console app on Mac and filter by subsystem
     */
    private let logger = Logger(
        subsystem: "network.ur.extension",
        category: "PacketTunnel"
    )

    private var deviceConfiguration: [String: String]?
    private var device: SdkDeviceLocal?
    private var localState: SdkLocalState?
    private var close: (() -> Void)?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryMonitor: ExtensionMemoryMonitor?
    private var fips140Enabled = false
    private var connected: Bool = false
    // NetworkExtension applies settings asynchronously. Listener bursts during
    // connect/reconnect used to overlap several identical applies; serialize
    // them and retain only the newest distinct pending plan.
    private let tunnelSettingsLock = NSLock()
    private var tunnelSettingsSessionActive = false
    private var tunnelSettingsGeneration: UInt64 = 0
    private var appliedTunnelSettingsSignature: String?
    private var tunnelSettingsInFlight: TunnelNetworkSettingsPlan?
    private var tunnelSettingsInFlightCompletions: [((Error?) -> Void)] = []
    private var pendingTunnelSettings: TunnelNetworkSettingsPlan?
    private var pendingTunnelSettingsForce = false
    private var pendingTunnelSettingsCompletions: [((Error?) -> Void)] = []
    private var stopped: Bool = false
    private var shouldSaveKeyMaterial: Bool = true
    private let packetReadLock = NSLock()
    // re-checks the network path + power state on demand (set per tunnel
    // session; used by wake() after sleep, when the sockets are stale)
    private var networkStateRefresh: (() -> Void)?
    private var packetReadGeneration: UInt64 = 0
    private let logoutProviderMessage = "logout"


    override init() {
        super.init()

        logger.info("[PacketTunnelProvider]init")

        fips140Enabled = SdkGetFips140Enabled()
        if fips140Enabled {
            logger.fault("[PacketTunnelProvider]FIPS 140 is outside the network-extension memory budget")
        }

        if #available(iOS 26, macOS 26, *) {
            // the memory limit in the PacketTunnelProvider is 50mib in iOS 16, 17, 18, 26
            // the binary and go runtime take about 16mib of that
            // see https://forums.developer.apple.com/forums/thread/73148?page=2
            //
            // SdkSetMemoryLimit sizes the global message pools (packet 12 :
            // large-object 2, of 34 parts) + go soft limit; the per-device
            // memory target is set separately at device creation. 32mb total
            // footprint budget for the constrained extension. At this target
            // the aggregate platform budget admits H1 + H3, so iOS keeps the
            // normal Auto policy. Smaller targets admit H1 first and leave H3
            // unstarted when the two carriers do not fit together.
#if os(iOS)
            SdkSetMemoryLimit(32 * 1024 * 1024)
#else
            SdkSetMemoryLimit(64 * 1024 * 1024)
#endif
        } else if #available(iOS 16, macOS 13, *) {
            #if os(iOS)
            SdkSetMemoryLimit(32 * 1024 * 1024)
            #else
            SdkSetMemoryLimit(48 * 1024 * 1024)
            #endif
        } else {
            // note provider is also disabled for these
            SdkSetMemoryLimit(8 * 1024 * 1024)
        }

        // respond to memory pressure events
        // see https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: nil)
        if let memoryPressureSource = memoryPressureSource {
            memoryPressureSource.setEventHandler { [weak self] in
                guard let self, let source = self.memoryPressureSource else {
                    return
                }
                let event = DispatchSource.MemoryPressureEvent(rawValue: source.data)
                if event.contains(.warning) || event.contains(.critical) {
                    self.memoryMonitor?.sample(event: "pressure-before-free")
                    SdkFreeMemory()
                    self.memoryMonitor?.sample(event: "pressure-after-free")
                }
            }
            memoryPressureSource.activate()
        }

        memoryMonitor = ExtensionMemoryMonitor(logger: logger)
        memoryMonitor?.start()
    }

    deinit {
        memoryMonitor?.sample(event: "deinit")
        memoryMonitor?.stop()
        memoryPressureSource?.cancel()
    }


    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping ((any Error)?) -> Void) {
        logger.info("[PacketTunnelProvider]start")
        memoryMonitor?.sample(event: "start-requested")

        guard !fips140Enabled else {
            completionHandler(NSError(domain: "network.ur.extension", code: 11, userInfo: [NSLocalizedDescriptionKey: "FIPS 140 exceeds the network extension memory budget"]))
            return
        }

        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            logger.error( "[PacketTunnelProvider]start failed - no providerConfiguration")
            completionHandler(NSError(domain: "network.ur.extension", code: 1, userInfo: [NSLocalizedDescriptionKey: "No provider configuration"]))
            return
        }


        guard let configuredByJwt = providerConfiguration["by_jwt"] as? String else {
            completionHandler(NSError(domain: "network.ur.extension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing by_jwt"]))
            return
        }

        guard let configuredInstanceId =
                providerConfiguration["instance_id"] as? String,
              !configuredInstanceId.isEmpty else {
            completionHandler(NSError(domain: "network.ur.extension", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing instance_id"]))
            return
        }

        // Add the profile snapshot to the immutable shared history before
        // selecting. This handles an OS-driven launch after the app refreshed
        // the profile but before either process wrote the v2 Keychain format.
        if !SharedTunnelJwtStore.save(
            byJwt: configuredByJwt,
            instanceId: configuredInstanceId
        ) {
            logger.error("[PacketTunnelProvider]could not migrate configured tunnel JWT")
        }
        // Prefer the freshest exact-instance token written by either process.
        let byJwt = SharedTunnelJwtStore.load(
            expectedInstanceId: configuredInstanceId
        ) ?? configuredByJwt

        guard let networkSpaceJson = providerConfiguration["network_space"] as? String else {
            completionHandler(NSError(domain: "network.ur.extension", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing network_space"]))
            return
        }

        // opaque PEM strings from the app, used verbatim (mTLS server cert+key
        // and pinned client cert)
        guard let rpcServerPem = providerConfiguration["rpc_server_pem"] as? String else {
            completionHandler(NSError(domain: "network.ur.extension", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing rpc_server_pem"]))
            return
        }

        guard let rpcClientPem = providerConfiguration["rpc_client_pem"] as? String else {
            completionHandler(NSError(domain: "network.ur.extension", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing rpc_client_pem"]))
            return
        }

        guard let rpcListenHostPort = providerConfiguration["rpc_listen_hostport"] as? String else {
            completionHandler(NSError(domain: "network.ur.extension", code: 9, userInfo: [NSLocalizedDescriptionKey: "Missing rpc_listen_hostport"]))
            return
        }


        var err: NSError?

        let instanceId = SdkParseId(configuredInstanceId, &err)
        if let err {
            completionHandler(err)
            return
        }
        guard let instanceId = instanceId else {
            completionHandler(NSError(domain: "network.ur.extension", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to parse instance_id"]))
            return
        }
        if !SharedTunnelJwtStore.save(
            byJwt: byJwt,
            instanceId: configuredInstanceId
        ) {
            logger.error("[PacketTunnelProvider]could not persist shared tunnel JWT")
        }


        // include the rpc material (cert + listen host/port) so a change across
        // launches recreates the device
        let deviceConfiguration = [
            "by_jwt": byJwt,
            "network_space": networkSpaceJson,
            "rpc_server_pem": rpcServerPem,
            "rpc_client_pem": rpcClientPem,
            "rpc_listen_hostport": rpcListenHostPort,
            "instance_id": instanceId.string(),
        ]


        if let device = self.device {
            if self.deviceConfiguration == deviceConfiguration && !device.getDone() {
                // already running
                // this would theoretically happen if start was called multiple times without stop
                completionHandler(nil)
                return
            }
        }

        // Supersede all reads and settings work from a previous tunnel before
        // replacing its device. Generation guards keep late callbacks from
        // tearing down the new session.
        self.stopPacketReads()
        self.endTunnelSettingsSession()

//        self.reasserting = true


        // create new device with latest config
        
        self.connected = false
        self.close?()
        self.close = nil
        self.device = nil
        self.deviceConfiguration = nil
        self.localState = nil
        


        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].path()
        let networkSpaceManager = SdkNewNetworkSpaceManager(documentsPath)

        var networkSpace: SdkNetworkSpace?
        do {
            try networkSpace = networkSpaceManager?.importNetworkSpace(fromJson: networkSpaceJson)
        } catch {
            completionHandler(error)
            return
        }

        guard let networkSpace = networkSpace else {
            completionHandler(NSError(domain: "network.ur.extension", code: 6, userInfo: [NSLocalizedDescriptionKey: "Network space is nil"]))
            return
        }

        guard let localState = networkSpace.getAsyncLocalState()?.getLocalState() else {
            completionHandler(NSError(domain: "network.ur.extension", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to get local state"]))
            return
        }

        let appVersionString: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let buildNumber: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"

        let localStateIsStale = hasStaleLocalState(localState, byJwt: byJwt, instanceId: instanceId)
        // device identity is device-scoped, not session-scoped: load the key
        // material even when the auth state is stale (token rotation,
        // re-login), so peers can keep verifying this device across sessions.
        // Only the explicit logout app message rotates the identity.
        let keyMaterial: SdkDeviceLocalKeyMaterial? = localState.getDeviceLocalKeyMaterial()

        let newDevice = SdkNewDeviceLocalWithMemoryTarget(
            networkSpace,
            byJwt,
            "ios-network-extension",
            deviceModel() ?? "ios-unknown",
            "\(appVersionString)-\(buildNumber)",
            instanceId,
            // rpc is started explicitly below with the per-session server pem
            false,
            keyMaterial,
            // the per-device memory target (split dns 2 : client 14 :
            // provider 4 inside the sdk, with the provider share backing the
            // client pair while providing is off), set explicitly where the
            // device is created; the process-level SdkSetMemoryLimit above
            // sizes the shared message pools and go soft limit
            20 * 1024 * 1024,
            &err
        )
        if let err {
            completionHandler(err)
            return
        }

        guard let device = newDevice else {
            completionHandler(NSError(domain: "network.ur.extension", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to create device"]))
            return
        }

        // DeviceLocal starts background work during construction. Until the
        // complete session close closure is installed below, any early return
        // must close it rather than leaving its Go graph alive in the extension.
        let startupCleanup = TunnelStartupCleanup {
            device.close()
        }

        // start the rpc server listening on the per-session host/port,
        // presenting the self-signed server certificate and requiring + pinning
        // the client certificate (mTLS) from the app
        do {
            try device.setRpcServer(rpcServerPem, clientCertPem: rpcClientPem, hostPort: rpcListenHostPort)
        } catch {
            startupCleanup.cleanUpNow()
            completionHandler(error)
            return
        }

        
        let packetReadGeneration = self.beginPacketReads()
        self.beginTunnelSettingsSession()
        self.reasserting = true

        // a stale auth state wipes the session state below, but never the
        // device identity: the loaded key material is re-persisted after the
        // wipe (see saveKeyMaterial() at the end of setup)
        prepareLocalStateForStart(localState, byJwt: byJwt, instanceId: instanceId, hasStaleLocalState: localStateIsStale)

        self.deviceConfiguration = deviceConfiguration
        self.device = device
        self.localState = localState
        self.shouldSaveKeyMaterial = true
        memoryMonitor?.sample(event: "device-created")

        // set glog dir
        let logsURL: URL
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            logsURL = cacheURL.appendingPathComponent("Logs")
        } else if let libURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            logsURL = libURL.appendingPathComponent("Logs")
        } else {
            // As a last resort, use the temporary directory
            logsURL = FileManager.default.temporaryDirectory.appendingPathComponent("Logs")
        }

        try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)

        SdkSetLogDir(logsURL.path, nil)

        // load initial device settings
        // these will be in effect until the app connects and sets the user values
        device.setTunnelStarted(true)
        device.setProvidePaused(true)
        if let location = localState.getConnectLocation() {
            device.setConnectLocation(location)
        }
        device.setProvideMode(localState.getProvideMode())
        device.setProvideControlMode(localState.getProvideControlMode())
        device.setProvideNetworkMode(localState.getProvideNetworkMode())
        device.setRouteLocal(localState.getRouteLocal())
        // the device restores the blocker from its own local state at creation,
        // but seed it here too: when the app and the extension do not share
        // storage, a toggle made before the tunnel ever ran would otherwise be
        // lost on the first start
        device.setBlockerEnabled(localState.getBlockerEnabled())
        device.setCanShowRatingDialog(localState.getCanShowRatingDialog())
        device.setCanPromptIntroFunnel(localState.getCanPromptIntroFunnel())
        device.setCanRefer(localState.getCanRefer())
        device.setAllowForeground(localState.getAllowForeground())
        device.setVpnInterfaceWhileOffline(localState.getVpnInterfaceWhileOffline())
        if let defaultLocation = localState.getDefaultLocation() {
            device.setDefaultLocation(defaultLocation)
        }
        if let performanceProfile = localState.getPerformanceProfile() {
            device.setPerformanceProfile(performanceProfile)
        }

//        let packetContext = ManagedAtomic<Int>(0)
//        let startPacketFlow = {
////            packetContext.wrappingIncrement(ordering: .relaxed)
//            self.readToDevice()
//        }

        let setLocal = {
            if device.getConnectLocation() == nil {
                // reset to local if available
                self.applyTunnelNetworkSettings { error in
                    if let error = error {
                        self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                        return
                    }
                    if device.getConnectLocation() == nil {
                        self.reasserting = false
                        //                    readToDevice(packetFlow: self.packetFlow, device: device)
//                        self.readToDevice()
                    }
                }
            }
        }

        let locationChangeSub = device.add(ConnectLocationChangeListener { location in
            try? localState.setConnectLocation(location)

            if device.getConnectLocation() == nil {
                DispatchQueue.main.async {
                    setLocal()
                }
            }
        })
        let saveKeyMaterial = {
            guard self.shouldSaveKeyMaterial else {
                return
            }

            guard let keyMaterial = device.getKeyMaterial(), !keyMaterial.isEmpty() else {
                return
            }

            do {
                try localState.setDeviceLocalKeyMaterial(keyMaterial)
            } catch {
                self.logger.error("[PacketTunnelProvider]failed to save device key material: \(error.localizedDescription)")
            }
        }
        let provideSecretKeysSub = device.add(ProvideSecretKeysListener { _ in
            saveKeyMaterial()
        })
        let jwtRefreshSub = device.add(TunnelJwtRefreshListener { jwt in
            guard let jwt, !jwt.isEmpty else { return }
            if !SharedTunnelJwtStore.save(
                byJwt: jwt,
                instanceId: configuredInstanceId
            ) {
                self.logger.error("[PacketTunnelProvider]could not save refreshed shared tunnel JWT")
            }
        })
        if let keyMaterial {
            device.setKeyMaterial(keyMaterial)
        }
        // persist the identity immediately: a freshly generated key must
        // survive this session even if no provide-key event fires, and a
        // loaded key must be re-written after a stale-state wipe
        saveKeyMaterial()

        let canShowRatingDialogChangeSub = device.add(CanShowRatingDialogChangeListener { canShowRatingDialog in
            try? localState.setCanShowRatingDialog(canShowRatingDialog)
        })
        let canPromptIntroFunnelChangeSub = device.add(CanPromptIntroFunnelChangeListener { canPromptIntroFunnel in
            try? localState.setCanPromptIntroFunnel(canPromptIntroFunnel)
        })
        let allowForegroundChangeSub = device.add(AllowForegroundChangeListener { allowForeground in
            try? localState.setAllowForeground(allowForeground)
        })
        let canReferChangeSub = device.add(CanReferChangeListener { canRefer in
            try? localState.setCanRefer(canRefer)
        })
        let provideModeChangeSub = device.add(ProvideModeChangeListener { provideMode in
            try? localState.setProvideMode(provideMode)
        })
        let provideChangeSub = device.add(ProvideChangeListener { provideEnabled in
            if provideEnabled && device.getConnectLocation() == nil {
                DispatchQueue.main.async {
                    setLocal()
                }
            }
        })
        let provideControlModeChangeSub = device.add(ProvideControlModeChangeListener { provideControlMode in
            guard let provideControlMode else {
                return
            }
            try? localState.setProvideControlMode(provideControlMode)
        })
        let performanceProfileChangeSub = device.add(PerformanceProfileChangeListener { performanceProfile in
            try? localState.setPerformanceProfile(performanceProfile)
        })
        let routeLocalChangeSub = device.add(RouteLocalChangeListener { routeLocal in
            try? localState.setRouteLocal(routeLocal)
        })
        let vpnInterfaceWhileOfflineChangeSub = device.add(VpnInterfaceWhileOfflineChangeListener { vpnInterfaceWhileOffline in
            try? localState.setVpnInterfaceWhileOffline(vpnInterfaceWhileOffline)
        })
        let defaultLocationChangeSub = device.add(DefaultLocationChangeListener { location in
            try? localState.setDefaultLocation(location)
        })
        // re-apply the network settings when the dns settings change the tunnel
        // dns servers (e.g. unencrypted local servers set or cleared)
        let dnsResolverSettingsChangeSub = device.add(DnsResolverSettingsChangeListener { _ in
            DispatchQueue.main.async {
                self.applyTunnelNetworkSettings { error in
                    if let error = error {
                        self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                    }
                }
            }
        })
        let updateWindowStatus = { (windowStatus: SdkWindowStatus?) in
            var connected = false
            if let windowStatus = windowStatus {
                connected = 0 < windowStatus.providerStateAdded
            }
            if self.connected != connected {
                self.connected = connected
                if !connected {
                    if device.getConnectLocation() == nil {
                        setLocal()
                    } else {
                        self.reasserting = true
//                        self.setTunnelNetworkSettings(self.networkSettings()) { error in
//                            if let error = error {
//                                self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
//                                return
//                            }
////                            readToDevice(packetFlow: self.packetFlow, device: device)
////                            startPacketFlow()
//                            self.readToDevice()
//                        }
                    }
                } else {
                    self.applyTunnelNetworkSettings { error in
                        if let error = error {
                            self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                            return
                        }
                        if connected {
                            self.reasserting = false
                            //                        readToDevice(packetFlow: self.packetFlow, device: device)
                            //                        startPacketFlow()
//                            self.readToDevice()
                        }
                    }
    //                self.reasserting = false
                }
            }
        }
        let windowStatusChangeSub = device.add(WindowStatusChangeListener { windowStatus in
            DispatchQueue.main.async {
                updateWindowStatus(windowStatus)
            }
        })

        let updatePath = { (path: Network.NWPath) in
            let canProvideOnCell = device.getProvideNetworkMode() == "all"
            let canProvideOnNetwork = canProvideOnNetwork(path: path, canProvideOnCell: canProvideOnCell)
            self.logger.info(
                "[PacketTunnelProvider]provider network update cell=\(canProvideOnCell) expensive=\(path.isExpensive) constrained=\(path.isConstrained) provide=\(canProvideOnNetwork)"
            )
            device.setProvidePaused(!canProvideOnNetwork)
        }
        let pathMonitor = NWPathMonitor.init(prohibitedInterfaceTypes: [.loopback, .other])
        let pathMonitorQueue = DispatchQueue(label: "network.ur.extension.pathMonitor")
        // signature of the physical path (the tunnel's utun is .other, excluded above):
        // only a material change — interface set, status, or gateways (an AP/subnet
        // roam keeps the interface name but changes the gateway) — kicks the transports.
        // all mutable path/power state below is confined to pathMonitorQueue.
        var lastPathSignature: String? = nil
        var lastPathConstrained: Bool = false
        // degraded performance: a device in low power mode, thermally throttled, or on
        // a constrained (Low Data Mode) path answers control pings slowly — ease the
        // SDK's liveness probe timings so slow is not misread as dead
        let updatePerformanceDegraded = {
            let processInfo = ProcessInfo.processInfo
            let degraded = processInfo.isLowPowerModeEnabled
                || processInfo.thermalState == .serious
                || processInfo.thermalState == .critical
                || lastPathConstrained
            device.setPerformanceDegraded(degraded)
        }
        let handlePathUpdate = { (path: Network.NWPath) in
            updatePath(path)
            lastPathConstrained = path.isConstrained
            updatePerformanceDegraded()
            let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
            let pathSignature = "\(path.status)|"
                + path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
                + "|" + gateways
            if let last = lastPathSignature, last != pathSignature {
                // the old sockets are likely bound to a dead path: re-dial the
                // platform transports and re-prove/re-warm the tunnel DoH now,
                // instead of waiting for ping timeouts to notice
                self.logger.info("[PacketTunnelProvider]network path changed, re-dialing transports")
                device.networkChanged()
            }
            lastPathSignature = pathSignature
        }
        pathMonitor.pathUpdateHandler = { path in
            handlePathUpdate(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
        // NEProvider.defaultPath is the VPN-aware default-path signal; it can lead the
        // physical monitor on transitions, so a change prompts a re-check of the
        // physical path signature (the signature dedups the double notification)
        let defaultPathObservation = self.observe(\.defaultPath) { _, _ in
            pathMonitorQueue.async {
                handlePathUpdate(pathMonitor.currentPath)
            }
        }
        // low power / thermal transitions ease or restore the probe timings
        let powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { _ in
            pathMonitorQueue.async { updatePerformanceDegraded() }
        }
        let thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            pathMonitorQueue.async { updatePerformanceDegraded() }
        }
        pathMonitorQueue.async { updatePerformanceDegraded() }
        // wake() re-dials and refreshes path/power state after sleep (see wake below)
        self.networkStateRefresh = {
            pathMonitorQueue.async {
                handlePathUpdate(pathMonitor.currentPath)
            }
        }
        let provideNetworkModeChangeSub = device.add( ProvideNetworkModeChangeListener { mode in
            if let mode {
                try? localState.setProvideNetworkMode(mode)
            }
            DispatchQueue.main.async {
                updatePath(pathMonitor.currentPath)
            }
        })


//        let packetWriteLock = NSLock()
        let packetReceiverSub = device.add(PacketBatchBytesReceiver { packetBatchBytes in
            autoreleasepool {
                var packets: [Data] = []
                var protocols: [NSNumber] = []
                packets.reserveCapacity(TunnelPacketBatchCodec.maxPacketCount)
                protocols.reserveCapacity(TunnelPacketBatchCodec.maxPacketCount)
                let valid = TunnelPacketBatchCodec.decode(packetBatchBytes) { packet, ipVersion in
                    packets.append(packet)
                    protocols.append((ipVersion == 4 ? AF_INET : AF_INET6) as NSNumber)
                }
                if valid && !packets.isEmpty {
                    // This is Connect's deliberate device-TUN receive
                    // exception: keep final NEPacketTunnelFlow injection
                    // synchronous so Transfer ACK follows accepted delivery.
                    self.packetFlow.writePackets(packets, withProtocols: protocols)
                }
            }
        })

        self.close = {
            packetReceiverSub?.close()
            defaultPathObservation.invalidate()
            NotificationCenter.default.removeObserver(powerStateObserver)
            NotificationCenter.default.removeObserver(thermalStateObserver)
            self.networkStateRefresh = nil
            pathMonitor.cancel()
            routeLocalChangeSub?.close()
            vpnInterfaceWhileOfflineChangeSub?.close()
            provideChangeSub?.close()
            provideModeChangeSub?.close()
            provideControlModeChangeSub?.close()
            canShowRatingDialogChangeSub?.close()
            canPromptIntroFunnelChangeSub?.close()
            allowForegroundChangeSub?.close()
            canReferChangeSub?.close()
            performanceProfileChangeSub?.close()
            provideSecretKeysSub?.close()
            jwtRefreshSub?.close()
            locationChangeSub?.close()
            defaultLocationChangeSub?.close()
            dnsResolverSettingsChangeSub?.close()
            windowStatusChangeSub?.close()
            provideNetworkModeChangeSub?.close()
//            packetContext.wrappingIncrement(ordering: .relaxed)
            device.close()
        }
        startupCleanup.commit()

//        Thread.setThreadPriority(1.0)
//        self.setTunnelNetworkSettings(self.networkSettings()) { _ in
////            startPacketFlow()
//            self.readToDevice()
//            updateWindowStatus(device.getWindowStatus())
//            completionHandler(nil)
//        }

        self.applyTunnelNetworkSettings(force: true) { error in
            DispatchQueue.main.async {
                guard self.isPacketReadActive(generation: packetReadGeneration) else {
                    completionHandler(NSError(domain: "network.ur.extension", code: 9, userInfo: [NSLocalizedDescriptionKey: "Tunnel start was superseded"]))
                    return
                }

                if let error {
                    self.logger.error("[PacketTunnelProvider]failed to set initial tunnel network settings: \(error.localizedDescription)")
                    self.stopPacketReads()
                    self.endTunnelSettingsSession()
                    if let close = self.close {
                        close()
                        self.close = nil
                    } else {
                        device.close()
                    }
                    self.device = nil
                    self.deviceConfiguration = nil
                    self.localState = nil
                    completionHandler(error)
                    return
                }

                updateWindowStatus(device.getWindowStatus())
                self.readToDevice(generation: packetReadGeneration)
                self.memoryMonitor?.sample(event: "tunnel-started")
                completionHandler(nil)
            }
        }
    }

    private func makeTunnelNetworkSettingsPlan() -> TunnelNetworkSettingsPlan {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // IPv4 Configuration
        let tunnelLocalAddress = self.device?.tunnelLocalAddress() ?? "169.254.2.1"
        let ipv4Settings = NEIPv4Settings(addresses: [tunnelLocalAddress], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        // exclude the local network from the tunnel, matching Android (MainService's
        // excludeRoute set): the RFC1918 private ranges bypass the tunnel so LAN
        // traffic reaches local devices directly. DNS is unaffected — it still routes
        // to the tunnel resolver via matchDomains below. The tunnel advertises no IPv6
        // settings, so there are no IPv6 tunnel routes to exclude.
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        ]
        networkSettings.ipv4Settings = ipv4Settings

        // Remote providers do not forward IPv6 yet. Keep the tunnel IPv4-only:
        // do not assign an IPv6 address, install IPv6 routes, or advertise an
        // IPv6 tunnel interface that applications might select.
        networkSettings.ipv6Settings = nil

        // DNS from the SDK device: the dns settings' unencrypted local servers
        // when set, otherwise the distinct plain-DNS UpgradeMux mask (see
        // `tunnelDnsServers`). Always plain :53, never OS-level
        // encrypted DNS (DoH/DoT): the UpgradeMux claims :53 and performs the
        // unencrypted-DNS -> DoH upgrade itself, so enabling encrypted DNS at the OS
        // level here (e.g. NEDNSOverHTTPSSettings/NEDNSOverTLSSettings) would bypass
        // the mux and hide queries from it.
        let dnsServers = self.tunnelDnsServers()
        let dnsSettings = NEDNSSettings(servers: dnsServers)
        // route every DNS query to the tunnel resolver (empty string matches all
        // domains). without this the OS may not send :53 queries into the tunnel, so
        // the UpgradeMux never sees them and resolution fails.
        dnsSettings.matchDomains = [""]
        networkSettings.dnsSettings = dnsSettings

        // Keep one full encrypted tunnel packet eligible for H3's single-
        // DATAGRAM lane. This is the same value used by provider packetization.
        let tunnelMtu = SdkGetDefaultTunnelMtu()
        networkSettings.mtu = NSNumber(value: tunnelMtu)

        let signature = "v4=\(tunnelLocalAddress)|v6=off|dns=\(dnsServers.joined(separator: ","))|mtu=\(tunnelMtu)"
        return TunnelNetworkSettingsPlan(
            settings: networkSettings,
            signature: signature
        )
    }

    private func beginTunnelSettingsSession() {
        resetTunnelSettingsSession(
            active: true,
            errorDescription: "Tunnel network settings session was superseded"
        )
    }

    private func endTunnelSettingsSession() {
        resetTunnelSettingsSession(
            active: false,
            errorDescription: "Tunnel network settings session stopped"
        )
    }

    private func resetTunnelSettingsSession(active: Bool, errorDescription: String) {
        tunnelSettingsLock.lock()
        tunnelSettingsGeneration &+= 1
        tunnelSettingsSessionActive = active
        appliedTunnelSettingsSignature = nil

        let callbacks = tunnelSettingsInFlightCompletions + pendingTunnelSettingsCompletions
        tunnelSettingsInFlight = nil
        tunnelSettingsInFlightCompletions = []
        pendingTunnelSettings = nil
        pendingTunnelSettingsForce = false
        pendingTunnelSettingsCompletions = []
        tunnelSettingsLock.unlock()

        guard !callbacks.isEmpty else {
            return
        }
        let error = NSError(
            domain: "network.ur.extension",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: errorDescription]
        )
        completeTunnelSettingsCallbacks(callbacks, error: error)
    }

    /**
     * Apply at most one NEPacketTunnelNetworkSettings transaction at a time.
     * Equal settings join the active transaction; if settings change while it
     * is active, only the newest plan is retained and applied next.
     */
    private func applyTunnelNetworkSettings(
        force: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        let plan = makeTunnelNetworkSettingsPlan()
        var start: (TunnelNetworkSettingsPlan, UInt64)?
        var immediateError: Error?
        var completeImmediately = false

        tunnelSettingsLock.lock()
        if !tunnelSettingsSessionActive {
            immediateError = NSError(
                domain: "network.ur.extension",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Tunnel network settings session is not active"]
            )
        } else if let inFlight = tunnelSettingsInFlight {
            if inFlight.signature == plan.signature {
                // Latest state has returned to the plan already in flight.
                // Cancel a different pending plan and let all its callers join
                // this transaction.
                tunnelSettingsInFlightCompletions.append(contentsOf: pendingTunnelSettingsCompletions)
                pendingTunnelSettings = nil
                pendingTunnelSettingsForce = false
                pendingTunnelSettingsCompletions = []
                if let completion {
                    tunnelSettingsInFlightCompletions.append(completion)
                }
            } else {
                pendingTunnelSettings = plan
                pendingTunnelSettingsForce = force
                if let completion {
                    pendingTunnelSettingsCompletions.append(completion)
                }
            }
        } else if !force, appliedTunnelSettingsSignature == plan.signature {
            completeImmediately = true
        } else {
            tunnelSettingsGeneration &+= 1
            let generation = tunnelSettingsGeneration
            tunnelSettingsInFlight = plan
            if let completion {
                tunnelSettingsInFlightCompletions = [completion]
            } else {
                tunnelSettingsInFlightCompletions = []
            }
            start = (plan, generation)
        }
        tunnelSettingsLock.unlock()

        if let immediateError {
            if let completion {
                completeTunnelSettingsCallbacks([completion], error: immediateError)
            }
            return
        }
        if completeImmediately {
            if let completion {
                completeTunnelSettingsCallbacks([completion], error: nil)
            }
            return
        }
        if let (plan, generation) = start {
            startTunnelSettingsApply(plan, generation: generation)
        }
    }

    private func startTunnelSettingsApply(
        _ plan: TunnelNetworkSettingsPlan,
        generation: UInt64
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.tunnelSettingsLock.lock()
            let valid = self.tunnelSettingsSessionActive
                && self.tunnelSettingsGeneration == generation
                && self.tunnelSettingsInFlight?.signature == plan.signature
            self.tunnelSettingsLock.unlock()
            guard valid else {
                return
            }

            self.setTunnelNetworkSettings(plan.settings) { [weak self] error in
                self?.finishTunnelSettingsApply(plan, generation: generation, error: error)
            }
        }
    }

    private func finishTunnelSettingsApply(
        _ plan: TunnelNetworkSettingsPlan,
        generation: UInt64,
        error: Error?
    ) {
        var completedCallbacks: [((Error?) -> Void)] = []
        var deduplicatedCallbacks: [((Error?) -> Void)] = []
        var start: (TunnelNetworkSettingsPlan, UInt64)?

        tunnelSettingsLock.lock()
        guard tunnelSettingsSessionActive,
              tunnelSettingsGeneration == generation,
              tunnelSettingsInFlight?.signature == plan.signature else {
            tunnelSettingsLock.unlock()
            return
        }

        completedCallbacks = tunnelSettingsInFlightCompletions
        tunnelSettingsInFlight = nil
        tunnelSettingsInFlightCompletions = []

        if error == nil {
            appliedTunnelSettingsSignature = plan.signature
        }

        if let pending = pendingTunnelSettings {
            let pendingForce = pendingTunnelSettingsForce
            let pendingCallbacks = pendingTunnelSettingsCompletions
            pendingTunnelSettings = nil
            pendingTunnelSettingsForce = false
            pendingTunnelSettingsCompletions = []

            if error == nil,
               !pendingForce,
               appliedTunnelSettingsSignature == pending.signature {
                deduplicatedCallbacks = pendingCallbacks
            } else {
                tunnelSettingsGeneration &+= 1
                let nextGeneration = tunnelSettingsGeneration
                tunnelSettingsInFlight = pending
                tunnelSettingsInFlightCompletions = pendingCallbacks
                start = (pending, nextGeneration)
            }
        }
        tunnelSettingsLock.unlock()

        if let (nextPlan, nextGeneration) = start {
            startTunnelSettingsApply(nextPlan, generation: nextGeneration)
        }
        completeTunnelSettingsCallbacks(completedCallbacks, error: error)
        completeTunnelSettingsCallbacks(deduplicatedCallbacks, error: nil)
    }

    private func completeTunnelSettingsCallbacks(
        _ callbacks: [((Error?) -> Void)],
        error: Error?
    ) {
        guard !callbacks.isEmpty else {
            return
        }
        DispatchQueue.main.async {
            for callback in callbacks {
                callback(error)
            }
        }
    }

    /// The plain-dns servers for the tunnel, from the sdk device like the tunnel
    /// address: the dns settings' unencrypted local servers when set, otherwise the
    /// default plain-DNS resolvers (which the UpgradeMux can intercept and upgrade).
    /// The tunnel is ipv4-only (no ipv6 addresses or routes), so only the ipv4
    /// resolvers apply.
    func tunnelDnsServers() -> [String] {
        var servers: [String] = []
        if let addresses = self.device?.tunnelDnsAddressesIpv4() {
            for i in 0..<addresses.len() {
                servers.append(addresses.get(i))
            }
        }
        if servers.isEmpty {
            // If the device-scoped value is unavailable, use the SDK's
            // URnetwork-owned UpgradeMux identity rather than advertising a
            // third-party resolver the OS could classify or reach directly.
            servers = [SdkGetDefaultTunnelDnsAddressIpv4()]
        }
        return servers
    }

    private func hasStaleLocalState(_ localState: SdkLocalState, byJwt: String, instanceId: SdkId) -> Bool {
        let storedByJwt = localState.getByJwt()
        let storedInstanceId = localState.getInstanceId()?.string()
        let instanceIdString = instanceId.string()

        return (!storedByJwt.isEmpty && storedByJwt != byJwt) ||
            (storedInstanceId != nil && storedInstanceId != instanceIdString)
    }

    private func prepareLocalStateForStart(_ localState: SdkLocalState, byJwt: String, instanceId: SdkId, hasStaleLocalState: Bool) {
        if hasStaleLocalState {
            do {
                try localState.logout()
            } catch {
                logger.error("[PacketTunnelProvider]failed to clear stale local state: \(error.localizedDescription)")
            }
        }

        do {
            try localState.setByJwt(byJwt)
            try localState.setInstanceId(instanceId)
        } catch {
            logger.error("[PacketTunnelProvider]failed to update local auth markers: \(error.localizedDescription)")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("[PacketTunnelProvider]stop with reason: \(String(describing: reason))")
        memoryMonitor?.sample(event: "tunnel-stopping")

        self.stopPacketReads()
        self.endTunnelSettingsSession()
        if let close = self.close {
            close()
            self.close = nil
        } else {
            self.device?.close()
        }
        self.device = nil
        self.localState = nil
        self.shouldSaveKeyMaterial = true
        memoryMonitor?.sample(event: "tunnel-stopped")
        completionHandler()
    }

    override func wake() {
        // returning from sleep: the transport sockets are stale — re-dial and
        // refresh the path/power state now instead of waiting for ping
        // timeouts to notice the dead connections
        logger.info("[PacketTunnelProvider]wake")
        device?.networkChanged()
        networkStateRefresh?()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(data: messageData, encoding: .utf8) == logoutProviderMessage {
            shouldSaveKeyMaterial = false
            SharedTunnelJwtStore.clear()
            do {
                try localState?.logout()
                deviceConfiguration = nil
                completionHandler?(Data("ok".utf8))
            } catch {
                logger.error("[PacketTunnelProvider]failed to clear local state on logout: \(error.localizedDescription)")
                completionHandler?(Data("error".utf8))
            }
            return
        }

        if let handler = completionHandler {
            handler(messageData)
        }
    }


    private func beginPacketReads() -> UInt64 {
        packetReadLock.lock()
        defer { packetReadLock.unlock() }

        stopped = false
        packetReadGeneration &+= 1
        return packetReadGeneration
    }

    private func stopPacketReads() {
        packetReadLock.lock()
        stopped = true
        packetReadGeneration &+= 1
        packetReadLock.unlock()
    }

    private func isPacketReadActive(generation: UInt64) -> Bool {
        packetReadLock.lock()
        defer { packetReadLock.unlock() }

        return !stopped && generation == packetReadGeneration
    }

    private func readToDevice(generation: UInt64) {
        guard isPacketReadActive(generation: generation) else { return }

        self.packetFlow.readPackets { packets, protocols in
            guard self.isPacketReadActive(generation: generation) else { return }

            if let device = self.device {
                TunnelPacketBatchCodec.encode(packets) { packetBatchBytes in
                    autoreleasepool {
                        _ = device.sendPacketBatch(packetBatchBytes)
                    }
                }
            }
            self.readToDevice(generation: generation)
        }
    }

}

private final class TunnelJwtRefreshListener: NSObject,
    SdkJwtRefreshListenerProtocol {
    private let callback: (String?) -> Void

    init(_ callback: @escaping (String?) -> Void) {
        self.callback = callback
    }

    func jwtRefreshed(_ jwt: String?) {
        callback(jwt)
    }
}


private class ProvideSecretKeysListener: NSObject, SdkProvideSecretKeysListenerProtocol {
    private let c: (_ provideSecretKeysList: SdkProvideSecretKeyList?) -> Void

    init(c: @escaping (_ provideSecretKeysList: SdkProvideSecretKeyList?) -> Void) {
        self.c = c
    }

    func provideSecretKeysChanged(_ provideSecretKeysList: SdkProvideSecretKeyList?) {
        c(provideSecretKeysList)
    }
}




private class PacketBatchBytesReceiver: NSObject, SdkReceivePacketBatchProtocol {
    func receivePacketBatch(_ packetBatchBytes: Data?) {
        if let packetBatchBytes {
            c(packetBatchBytes)
        }
    }

    private let c: (Data) -> Void

    init(c: @escaping (Data) -> Void) {
        self.c = c
    }

}


private class ConnectLocationChangeListener: NSObject, SdkConnectLocationChangeListenerProtocol {

    private let c: (_ location: SdkConnectLocation?) -> Void

    init(c: @escaping (_ location: SdkConnectLocation?) -> Void) {
        self.c = c
    }

    func connectLocationChanged(_ location: SdkConnectLocation?) {
        c(location)
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

private class ProvideControlModeChangeListener: NSObject, SdkProvideControlModeChangeListenerProtocol {

    private let c: (_ provideControlMode: String?) -> Void

    init(c: @escaping (_ provideControlMode: String?) -> Void) {
        self.c = c
    }

    func provideControlModeChanged(_ provideControlMode: String?) {
        c(provideControlMode)
    }
}

private class PerformanceProfileChangeListener: NSObject, SdkPerformanceProfileChangeListenerProtocol {

    private let c: (_ performanceProfile: SdkPerformanceProfile?) -> Void

    init(c: @escaping (_ performanceProfile: SdkPerformanceProfile?) -> Void) {
        self.c = c
    }

    func performanceProfileChanged(_ performanceProfile: SdkPerformanceProfile?) {
        c(performanceProfile)
    }
}

private class RouteLocalChangeListener: NSObject, SdkRouteLocalChangeListenerProtocol {

    private let c: (_ routeLocal: Bool) -> Void

    init(c: @escaping (_ routeLocal: Bool) -> Void) {
        self.c = c
    }

    func routeLocalChanged(_ routeLocal: Bool) {
        c(routeLocal)
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

private class WindowStatusChangeListener: NSObject, SdkWindowStatusChangeListenerProtocol {

    private let c: (_ windowStatus: SdkWindowStatus?) -> Void

    init(c: @escaping (_ windowStatus: SdkWindowStatus?) -> Void) {
        self.c = c
    }

    func windowStatusChanged(_ windowStatus: SdkWindowStatus?) {
        c(windowStatus)
    }
}

private class DnsResolverSettingsChangeListener: NSObject, SdkDnsResolverSettingsChangeListenerProtocol {

    private let c: (_ dnsResolverSettings: SdkDnsResolverSettings?) -> Void

    init(c: @escaping (_ dnsResolverSettings: SdkDnsResolverSettings?) -> Void) {
        self.c = c
    }

    func dnsResolverSettingsChanged(_ dnsResolverSettings: SdkDnsResolverSettings?) {
        c(dnsResolverSettings)
    }
}

private class ProvideNetworkModeChangeListener: NSObject, SdkProvideNetworkModeChangeListenerProtocol {

    private let c: (_ mode: String?) -> Void

    init(c: @escaping (_ mode: String?) -> Void) {
        self.c = c
    }

    func provideNetworkModeChanged(_ provideNetworkMode: String?) {
        c(provideNetworkMode)
    }

}



func canProvideOnNetwork(path: Network.NWPath, canProvideOnCell: Bool) ->  Bool {
    // TODO it seems like iOS 16,17 have more issues than 18, but the root cause is unknown
    if #available(iOS 18, macOS 15, *) {
        // Low Data Mode is an explicit request to reduce data use, so never
        // provide while the physical path is constrained. An expensive Wi-Fi
        // path is commonly a Personal Hotspot and must not be treated like
        // unmetered Wi-Fi. Cellular remains available only through the user's
        // explicit "Allow providing on cellular network" setting.
        if path.isConstrained {
            return false
        }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return !path.isExpensive
        }
        if path.usesInterfaceType(.cellular) {
            return canProvideOnCell
        }
        return false
    } else {
        // not enough memory in the extension
        // see memory notes at top
        return false
    }
}

func deviceModel() -> String? {
    var systemInfo = utsname()
    uname(&systemInfo)
    let modelCode = withUnsafePointer(to: &systemInfo.machine) { uptr in
        uptr.withMemoryRebound(to: CChar.self, capacity: 1) {
            ptr in String.init(validatingUTF8: ptr)
        }
    }
    return modelCode
}
