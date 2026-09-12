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

private enum SharedTunnelJwtStore {
    private static let service = "network.ur.shared-tunnel-jwt"
    private static let accountPrefix = "v2-"
    private static let retainedTokensPerInstance = 3

    static func load(expectedInstanceId: String, configuredByJwt: String) -> String? {
        let dates = jwtDates(configuredByJwt)
        let configured = account(byJwt: configuredByJwt, instanceId: expectedInstanceId).map {
            TunnelStartupJwtCandidate(
                account: $0,
                byJwt: configuredByJwt,
                issuedAt: dates.issuedAt,
                expiresAt: dates.expiresAt
            )
        }
        return selectTunnelStartupClient(
            configured: configured,
            persisted: loadCandidates(expectedInstanceId: expectedInstanceId)
        )
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
    ) -> [TunnelStartupJwtCandidate] {
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
    ) -> TunnelStartupJwtCandidate? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(
            SharedTunnelJwtEnvelope.self,
            from: data
        ), envelope.version == SharedTunnelJwtEnvelope.currentVersion,
           envelope.instanceId == expectedInstanceId,
           !envelope.byJwt.isEmpty {
            return TunnelStartupJwtCandidate(
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
            return TunnelStartupJwtCandidate(
                account: account,
                byJwt: legacy.byJwt,
                issuedAt: dates.issuedAt,
                expiresAt: dates.expiresAt
            )
        }
        return nil
    }

    private static func prune(expectedInstanceId: String) {
        let candidates = loadCandidates(expectedInstanceId: expectedInstanceId)
        guard candidates.count > retainedTokensPerInstance else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let keep = Set(
            candidates.sorted { TunnelStartupJwtCandidate.isPreferred($0, over: $1, now: now) }
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
    private let lifecycleId = String(UUID().uuidString.prefix(8))
    private let lifecycleLock = NSLock()
    private var sleepStartedAt: Date?

    private struct ProviderSession {
        let device: SdkDeviceLocal
        let localState: SdkLocalState
        var configuration: [String: String]?
        var close: (() -> Void)?
        var snapshotWriter: WidgetSnapshotWriter?
        var networkStateRefresh: (() -> Void)?
        var destinationRecovery: DestinationRecovery?
        var recoveryEffects: RecoveryEffects?
        var connected = false
        var started = false
        var shouldSaveKeyMaterial = true
    }
    private let providerSessions = TunnelProviderSessionOwner<ProviderSession>()
    // Readers take retained, coherent references. Publication/update/take below
    // carries the reservation ticket; a stale callback cannot write a new slot.
    private var device: SdkDeviceLocal? { providerSessions.snapshot()?.value.device }
    private var localState: SdkLocalState? { providerSessions.snapshot()?.value.localState }
    private var deviceConfiguration: [String: String]? { providerSessions.snapshot()?.value.configuration }
    private var shouldSaveKeyMaterial: Bool { providerSessions.snapshot()?.value.shouldSaveKeyMaterial ?? false }
    private var networkStateRefresh: (() -> Void)? { providerSessions.snapshot()?.value.networkStateRefresh }
    private var connected: Bool { providerSessions.snapshot()?.value.connected ?? false }
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryMonitor: ExtensionMemoryMonitor?
    private var fips140Enabled = false
    private typealias RecoverySession = TunnelRecoverySession<TunnelIntentOwner, TunnelIntent>
    private typealias DestinationRecovery = TunnelAuthRecoveryContinuation<RecoverySession.DestinationTicket>
    private typealias RecoveryEffects = TunnelRecoveryEffectScheduler<RecoverySession.DestinationTicket>
    private let recoverySession = RecoverySession()
    private var recoveryBreadcrumbs: [String: String] = [:]
    private let recoveryBreadcrumbLock = NSLock()
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
    private let packetReads = TunnelPacketReadOwner()
    // Main-queue-only recovery state. Path and lifecycle signals are coalesced
    // here so wake + NWPath cannot tear down the same reconnect attempt twice.
    private var transportRecoveryWork: DispatchWorkItem?
    private var recoveryNeedsTransportChange = false
    private var recoveryWorkGeneration: UInt64 = 0
    private var wakeHealthWork: DispatchWorkItem?
    private var lastTransportRecoveryAt: Date?
    private let transportRecoveryDebounce: TimeInterval = 0.350
    private let minimumTransportRecoveryInterval: TimeInterval = 2
    private let wakeHealthGrace: TimeInterval = 5
    private let logoutProviderMessage = "logout"
    // the app asks for this immediately before it reads this process's log
    // files for a diagnostic export
    private let flushLogsProviderMessage = "flush-logs"


    override init() {
        super.init()

        // FIRST, before anything that can log or fail: glog writes nothing
        // anywhere until SetLogDirForProcess has run, so every line emitted
        // before this point is lost. This used to sit inside startTunnel after
        // device creation, past seventeen completionHandler(...)/return paths
        // -- so a tunnel that failed to start produced no extension log files
        // at all, and the diagnostic export of the most diagnostically
        // valuable window the feature exists to capture came back empty with
        // nothing saying why.
        ExtensionDiagnosticsLogLocation.configure()

        logger.info("[PacketTunnelProvider][\(self.lifecycleId)] init")

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
        logger.info("[PacketTunnelProvider][\(self.lifecycleId)] start")
        recordRecoveryStage("startup", "started")
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

        // Include the profile snapshot in read-only freshness selection. An
        // aborted startup must not publish a speculative shared-history item.
        let byJwt = SharedTunnelJwtStore.load(
            expectedInstanceId: configuredInstanceId,
            configuredByJwt: configuredByJwt
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
        // include the rpc material (cert + listen host/port) so a change across
        // launches recreates the device
        var deviceConfiguration = [
            "by_jwt": byJwt,
            "network_space": networkSpaceJson,
            "rpc_server_pem": rpcServerPem,
            "rpc_client_pem": rpcClientPem,
            "rpc_listen_hostport": rpcListenHostPort,
            "instance_id": instanceId.string(),
        ]


        // Reservation and old bookkeeping retirement share one admission.
        // Detached settings/cancellation callbacks run only after owner unlock.
        var previousRecovery: RecoverySession.Snapshot?
        var previousSettings: TunnelSettingsSessionTransition?
        let providerTicket: TunnelProviderSessionOwner<ProviderSession>.Ticket
        let previousProvider: ProviderSession?
        switch providerSessions.beginStartup(isAlreadyRunning: { existing in
            existing.started && existing.configuration == deviceConfiguration && !existing.device.getDone()
        }, prepareWithLock: {
            self.stopPacketReads()
            previousSettings = self.prepareTunnelSettingsSession(active: false)
            previousRecovery = self.recoverySession.prepareRetire()
            self.recoveryBreadcrumbLock.lock()
            self.recoveryBreadcrumbs.removeAll()
            self.recoveryBreadcrumbLock.unlock()
        }, enqueue: { work in
            DispatchQueue.main.async(execute: work)
        }, cancelRecovery: { [weak self] in
            self?.cancelPendingTransportRecovery()
        }) {
        case .alreadyRunning:
            finishTunnelStartup(
                recordOutcome: {
                    self.recordRecoveryStage("startup", "preserved")
                },
                flushLogs: {
                    SdkFlushGlog()
                },
                completion: {
                    completionHandler(nil)
                }
            )
            return
        case .unavailable:
            completionHandler(TunnelLocalAuthIdentityError.superseded)
            return
        case .reserved(let ticket, let previous):
            providerTicket = ticket
            previousProvider = previous
        }
        defer {
            // An early constructor/read failure also retires its unpublished
            // reservation, without touching a newer start's slot.
            if providerSessions.snapshot(ticket: providerTicket) == nil { providerSessions.take(providerTicket) }
        }
        previousProvider?.destinationRecovery?.cancel()
        previousProvider?.recoveryEffects?.cancel()
        self.recoverySession.completeRetirement(previousRecovery)
        self.completeTunnelSettingsTransition(previousSettings, errorDescription: "Tunnel network settings session was superseded")
        if let close = previousProvider?.close { close() }
        else { previousProvider?.device.close() }
        


        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].path()
        let networkSpaceManager = SdkNewNetworkSpaceManager(documentsPath)
        // Import, auth reads and selection can fail before a device owns
        // this manager. Release those workers on every early return.
        let managerStartupCleanup = TunnelStartupCleanup {
            networkSpaceManager?.close()
        }

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

        // Conditional reset returns the exact keys it preserved under its
        // auth/storage lock. A failed ordinary read cannot become fresh keys.
        var keyMaterial: SdkDeviceLocalKeyMaterial?
        var initialAuthSnapshot: SdkLocalAuthStateSnapshot?
        var didResetAuth = false
        let configuredOwner = TunnelIntentOwner.make(
            instanceId: configuredInstanceId, clientJwt: byJwt, networkSpaceJson: networkSpaceJson
        )

        // KNOWN LIMITATION -- the control-plane ip family force is Auto here
        // for the FIRST connect after it is set with the tunnel down, and
        // that is deliberate.
        //
        // importNetworkSpace above restores the persisted policy from THIS
        // process's container. A force set while the tunnel was down lives
        // only in the app's container, so the restore finds nothing; the
        // device below starts control-plane work during construction (the
        // provider's platform websocket dial and the api jwt refresh both go
        // out before this function returns), and the rpc listener that
        // carries the app's queued policy is not opened until setRpcServer
        // further down. The app's first sync lands roughly a second later --
        // after those dials are already issued, so it governs what follows
        // rather than rescuing them.
        //
        // Not closed, because the cost is one repetition of a cost the
        // Automatic path already pays on every single connect. The sdk's
        // demotion ledger is in-memory and process-global, so a fresh
        // extension process starts with an empty one every time: an
        // unforced user re-learns the bad family, at the price of one
        // stalled first handshake, on every connect.
        //
        // That price is bounded and known: ControlFamilyFirstHandshakeTimeout,
        // 8s -- the floor connect puts on the first handshake of a control
        // dial so the retry over the other family still has budget to run
        // (connect/control_family_dial.go). The api jwt refresh is the dial
        // that pays it and the dial that learns; the platform websocket
        // arrives with gorilla's 5s cap, which is under 8s +
        // ControlFamilyRetryReserve, so connect leaves that handshake
        // unbounded and it inherits the answer from the process-global ledger
        // instead of paying for its own. (An earlier revision of this comment
        // said ~3s. That figure came from a budget-halving helper which has
        // since been deleted in favour of the floor, and it was wrong from the
        // moment the floor landed.)
        //
        // The force-setter pays that same 8s once and is then strictly better
        // off, because the sync persists the policy into this process's own
        // container and every later start restores it here.
        //
        // The regimes that actually hurt are already covered: the app
        // process dials pre-login and with the tunnel down, and there the
        // force is in effect the moment it is set -- which is the state a
        // user is in when they open the Developer menu to reach for it.
        //
        // Every available fix (a key in providerConfiguration, the
        // startTunnel options dict, or the group.network.ur App Group) works
        // by copying a preference into a durable store owned by the OS or by
        // the filesystem, beside LocalState which already owns it. That is a
        // second, staleable source of truth and a third channel for
        // preferences into this process, bought for one stalled 8s handshake
        // on one connect of a developer-only setting. It also contradicts the
        // contract the rest of this block states plainly below: the extension
        // seeds from its own local state, and those values hold "until the app
        // connects and sets the user values".

        let device: SdkDeviceLocal
        do {
            device = try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    do {
                        let snapshot = try networkSpace.getAuthStateSnapshot()
                        initialAuthSnapshot = snapshot
                        let storedClient = snapshot.getByClientJwt()
                        let storedOwner = snapshot.getInstanceId().flatMap {
                            TunnelIntentOwner.make(
                                instanceId: $0.string(), clientJwt: storedClient,
                                networkSpaceJson: networkSpaceJson
                            )
                        }
                        if !storedClient.isEmpty && storedOwner == nil {
                            throw TunnelLocalAuthIdentityError.incomplete
                        }
                        self.recordRecoveryStage("auth-observation", "accepted")
                        return TunnelLocalAuthIdentitySnapshot(
                            isEmpty: snapshot.getEmpty(),
                            instanceId: snapshot.getInstanceId()?.string(),
                            knownClientOwnerConflict: storedOwner.flatMap { stored in
                                configuredOwner.map { !stored.matches($0) }
                            } ?? false
                        )
                    } catch {
                        self.recordRecoveryStage("auth-observation", "failed")
                        throw error
                    }
                },
                clearStaleState: {
                    do {
                        guard let initialAuthSnapshot else {
                            throw TunnelLocalAuthIdentityError.superseded
                        }
                        let result = try networkSpace.resetLocalStateIfCurrent(initialAuthSnapshot)
                        try requireTunnelResetCompleted(result.getReset())
                        didResetAuth = true
                        keyMaterial = result.getDeviceLocalKeyMaterial()
                        self.recordRecoveryStage("auth-reset", "completed")
                    } catch {
                        self.recordRecoveryStage("auth-reset", "failed")
                        throw error
                    }
                },
                selectClientJwt: {
                    // Read-only selection. The constructor commits its client
                    // and instance only when the replacement can publish.
                    try checkedTunnelSdkValue {
                        localState.selectClientJwt(forInstance: byJwt, instanceId: instanceId, error: $0)
                    }
                },
                startSession: { selectedClientJwt in
                    if !didResetAuth {
                        self.recordRecoveryStage("auth-reset", "preserved")
                        do {
                            keyMaterial = try localState.readDeviceLocalKeyMaterial().getKeyMaterial()
                            self.recordRecoveryStage("key-load", keyMaterial == nil ? "missing" : "present")
                        } catch {
                            self.recordRecoveryStage("key-load", "failed")
                            throw error
                        }
                    }
                    self.recordRecoveryStage("auth-observation", "accepted")
                    let newDevice = SdkNewDeviceLocalWithMemoryTarget(
                        networkSpace,
                        selectedClientJwt,
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
                        newDevice?.close()
                        throw err
                    }
                    guard let newDevice else {
                        throw NSError(
                            domain: "network.ur.extension", code: 8,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to create device"]
                        )
                    }
                    return newDevice
                }
            )
        } catch {
            self.recordRecoveryStage("startup", "failed")
            logger.error("[PacketTunnelProvider]failed to prepare local auth state")
            completionHandler(error)
            return
        }
        // DeviceLocal starts background work during construction. Until the
        // complete session close closure is installed below, any early return
        // must close it and its manager. This owner is later retained by the
        // session close closure, not disarmed before RPC/settings setup.
        let startupCleanup = TunnelStartupCleanup {
            device.close()
            // The manager joins its API and async-storage workers. This
            // lifecycle path is outside SDK auth callbacks; it must not be
            // moved into one of those callbacks, where it could self-join.
            networkSpaceManager?.close()
        }
        managerStartupCleanup.commit()

        let acceptedOwner = TunnelIntentOwner.make(
            instanceId: configuredInstanceId, clientJwt: device.getClientJwt(),
            networkSpaceJson: networkSpaceJson
        )
        let savedLocationHasCurrentOwner = !(initialAuthSnapshot?.getEmpty() ?? true) && !didResetAuth
        let readDiagnostics = {
            RecoverySession.Diagnostics(
                consumerPresent: device.getConnectEnabled(),
                hasLocation: device.getConnectLocation() != nil,
                providerCount: Int64(device.getWindowStatus()?.providerStateAdded ?? -1)
            )
        }
        var admitted: (packet: UInt64, recovery: RecoverySession.Ticket)?
        var publicationRecovery: RecoverySession.Snapshot?
        var publicationSettings: TunnelSettingsSessionTransition?
        guard providerSessions.publish(
            ProviderSession(device: device, localState: localState, configuration: deviceConfiguration),
            ticket: providerTicket,
            prepareWithLock: {
                let packet = self.beginPacketReads()
                let settings = self.prepareTunnelSettingsSession(active: true)
                let (recovery, previous) = self.recoverySession.prepareBegin(
                    owner: acceptedOwner, savedLocationHasCurrentOwner: savedLocationHasCurrentOwner,
                    readDiagnostics: readDiagnostics
                )
                publicationSettings = settings
                publicationRecovery = previous
                admitted = (packet, recovery)
            }
        ), let admitted else {
            startupCleanup.cleanUpNow()
            completionHandler(TunnelLocalAuthIdentityError.superseded)
            return
        }
        let packetReadGeneration = admitted.packet
        let packetOrigin = TunnelPacketReadOrigin(device: device, generation: packetReadGeneration)
        let sessionTicket = admitted.recovery
        self.recoverySession.completeRetirement(publicationRecovery)
        self.completeTunnelSettingsTransition(publicationSettings, errorDescription: "Tunnel network settings session was superseded")
        self.reasserting = true
        memoryMonitor?.sample(event: "device-created")
        let currentProvider = {
            guard let state = self.providerSessions.snapshot(ticket: providerTicket) else { return false }
            return state.value.shouldSaveKeyMaterial && !device.getDone()
        }
        let currentAuthSnapshot = { () throws -> SdkLocalAuthStateSnapshot in
            do {
                guard self.recoverySession.isCurrent(sessionTicket),
                      currentProvider() else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                let snapshot = try networkSpace.getAuthStateSnapshot()
                guard snapshot.getInstanceId()?.string() == configuredInstanceId else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                if let acceptedOwner {
                    guard let currentOwner = TunnelIntentOwner.make(
                        instanceId: configuredInstanceId, clientJwt: snapshot.getByClientJwt(),
                        networkSpaceJson: networkSpaceJson
                    ), acceptedOwner.matches(currentOwner) else {
                        throw TunnelLocalAuthIdentityError.superseded
                    }
                } else if snapshot.getByClientJwt() != device.getClientJwt() {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                self.recordRecoveryStage("auth-observation", "accepted")
                return snapshot
            } catch {
                let result = (error as NSError).localizedDescription == "auth snapshot was superseded or is not settled"
                    ? "superseded" : "failed"
                self.recordRecoveryStage("auth-observation", result)
                throw error
            }
        }
        let readSharedIntent = { () throws -> TunnelIntent? in
            do {
                let intent = try TunnelIntentStore.loadChecked()
                self.recordRecoveryStage("intent-load", intent == nil ? "missing" : "present")
                return intent
            } catch {
                self.recordRecoveryStage("intent-load", "failed")
                throw error
            }
        }
        let restoreDestinationOnce = { (expected: RecoverySession.DestinationTicket?) throws -> Void in
            guard let state = self.recoverySession.snapshot(ticket: sessionTicket),
                  expected == nil || expected == state.destinationTicket else {
                throw TunnelLocalAuthIdentityError.superseded
            }
            let destinationTicket = state.destinationTicket
            let currentDestinationTicket = {
                self.recoverySession.isCurrent(destinationTicket)
                    && currentProvider() && self.isPacketReadActive(generation: packetReadGeneration)
            }
            _ = try currentAuthSnapshot()
            let sharedIntent = try readSharedIntent()
            let intent: TunnelDestinationIntent
            if let sharedIntent, sharedIntent.applies(to: acceptedOwner) {
                intent = sharedIntent.connect ? .connect : .disconnect
            } else {
                intent = .none
            }
            let plan = try restoreTunnelDestination(
                intent: intent,
                savedLocationHasCurrentOwner: state.savedLocationHasCurrentOwner,
                loadSaved: { device.getConnectLocation() },
                loadDefault: {
                    guard !state.defaultPreferenceUnavailable else {
                        throw TunnelLocalAuthIdentityError.unavailable
                    }
                    return device.getDefaultLocation()
                },
                bestAvailable: {
                    let id = SdkConnectLocationId()
                    id.bestAvailable = true
                    let location = SdkConnectLocation()
                    location.connectLocationId = id
                    return location
                },
                isCurrent: {
                    guard currentDestinationTicket() else { return false }
                    do { return try TunnelIntentStore.loadChecked() == sharedIntent }
                    catch {
                        self.recordRecoveryStage("intent-load", "failed")
                        return false
                    }
                },
                apply: { plan in
                    let location = plan.location
                    guard self.recoverySession.acceptDestination(
                        destinationTicket, present: location != nil, observedIntent: sharedIntent,
                        savedLocationIsVerified: plan.stage == .saved
                    ) else { throw TunnelLocalAuthIdentityError.superseded }
                    if plan.stage == .saved && device.getConnectEnabled() { return }
                    if plan.stage == .localOnly && device.getConnectLocation() == nil { return }
                    // Only a missing consumer for a current intended route
                    // needs reconstruction. Healthy existing clients retain
                    // the SDK's idempotent destination path.
                    do {
                        try applyTunnelRecoveryDestination(device, location: location)
                        if let current = self.recoverySession.snapshot(ticket: sessionTicket) {
                            self.recoverySession.savedLocationPersisted(current.destinationTicket)
                            self.recordRecoveryStage("destination-persist", "completed", snapshot: current)
                        }
                    } catch {
                        // A checked mutation can commit storage and then
                        // fail during live application. Its SDK operation
                        // record distinguishes those stages; error alone
                        // cannot establish whether persistence completed.
                        if let current = self.recoverySession.snapshot(ticket: sessionTicket) {
                            self.recordRecoveryStage("destination", "failed", snapshot: current)
                        }
                        throw error
                    }
                },
                report: { self.recordRecoveryStage($0, $1) }
            )
            self.recordRecoveryStage("destination", plan.location == nil ? "local" : "restored")
        }
        // Retain the existing callback shape. Post-start work below supplies
        // its original destination ticket and waits for actual publication.
        let restoreDestination = { () throws -> Void in
            try restoreDestinationOnce(nil)
        }

        // Load only authenticated existing preferences (or the known-empty
        // result of a completed reset). Fresh auth cannot adopt orphan files.
        // The SDK owns current/default read, atomic save, and live adoption.
        device.setTunnelStarted(true)
        device.setProvidePaused(true)
        // Confined to the initial caller and then the serial startup worker.
        // A changed finish-time intent repeats destination reconciliation,
        // never a successful Load/autosave preparation.
        var initialPreferencesPrepared = false
        let restoreInitialPreferences = { () throws -> Void in
            if initialPreferencesPrepared {
                try restoreDestinationOnce(nil)
                return
            }
            let initialSharedIntent = try readSharedIntent()
            let initialIntent: TunnelDestinationIntent
            if let initialSharedIntent, initialSharedIntent.applies(to: acceptedOwner) {
                initialIntent = initialSharedIntent.connect ? .connect : .disconnect
            } else {
                initialIntent = .none
            }
            let currentStartup = {
                self.recoverySession.isCurrent(sessionTicket)
                    && currentProvider()
                    && self.isPacketReadActive(generation: packetReadGeneration)
            }
            let snapshot = try currentAuthSnapshot()
            let loaded: SdkDeviceLocalLoadResult? = try loadTunnelPreferences(
                intent: initialIntent,
                loadOwnedPreferences: !(initialAuthSnapshot?.getEmpty() ?? true) || didResetAuth,
                isCurrent: {
                    guard currentStartup() else { return false }
                    return try readSharedIntent() == initialSharedIntent
                },
                persistDisconnect: { try snapshot.setConnectLocation(nil) },
                load: {
                    let result = try device.load()
                    guard result.getLoaded() else {
                        throw TunnelLocalAuthIdentityError.unavailable
                    }
                    return result
                },
                enableAutoSave: { try device.setAutoSave(true) },
                report: { self.recordRecoveryStage($0, $1) }
            )
            let defaultUnavailable = loaded.map { !$0.getDefaultError().isEmpty } ?? false
            guard self.recoverySession.observeDefaultPreference(sessionTicket, unavailable: defaultUnavailable) else {
                throw TunnelLocalAuthIdentityError.superseded
            }
            if let loaded {
                self.recordRecoveryStage("saved-load", loaded.getHasConnectLocation() ? "present" : "missing")
                self.recordRecoveryStage("default-load", defaultUnavailable ? "failed" : (loaded.getHasDefaultLocation() ? "present" : "missing"))
                if defaultUnavailable { self.recordRecoveryStage("consumer", "preserved") }
            }
            initialPreferencesPrepared = true
            try restoreDestinationOnce(nil)
        }
        let finishStartup = { [self] in
            // The SDK's checked Load owns the full local preference catalog.
            // Native code retains intent, keys/auth and OS/path observations;
            // it must not replay orphan preferences after an unowned skip.

    //        let packetContext = ManagedAtomic<Int>(0)
    //        let startPacketFlow = {
    ////            packetContext.wrappingIncrement(ordering: .relaxed)
    //            self.readToDevice()
    //        }

            let reconcileReadiness = {
                guard let state = self.recoverySession.snapshot(ticket: sessionTicket),
                      self.device === device, !device.getDone(),
                      self.isPacketReadActive(generation: packetReadGeneration) else { return }
                let providerCount = device.getWindowStatus()?.providerStateAdded ?? 0
                let next = tunnelReadiness(
                    connectIntended: state.connectIntended || device.getConnectLocation() != nil,
                    consumerPresent: device.getConnectEnabled(), providerCount: providerCount
                )
                let dnsOwned = device.getTunnelDnsInterceptorActive()
                guard let ticket = state.readiness.begin(.init(readiness: next, dnsOwned: dnsOwned)) else { return }
                guard self.providerSessions.update(providerTicket, { $0.connected = next == .connected }) else { return }
                self.reasserting = true
                self.recordRecoveryStage("readiness", next.rawValue)
                self.recordRecoveryStage("dns", dnsOwned ? "owned" : "unowned")
                self.applyTunnelNetworkSettings(device: device, providerTicket: providerTicket) { error in
                    guard self.recoverySession.isCurrent(sessionTicket), self.device === device,
                          self.isPacketReadActive(generation: packetReadGeneration) else { return }
                    switch state.readiness.complete(ticket, succeeded: error == nil) {
                    case .stale:
                        return
                    case .failed(let retry):
                        self.recordRecoveryStage("settings", "failed")
                        if retry { self.scheduleTransportRecovery(reason: "settings-retry", changeTransport: false) }
                    case .applied:
                        self.reasserting = next == .establishing
                        self.recordRecoveryStage("settings", "applied")
                    }
                }
            }
            guard recoverySession.installCallbacks(
                ticket: sessionTicket, restoreDestination: restoreDestination,
                reconcileReadiness: reconcileReadiness
            ) else {
                startupCleanup.cleanUpNow()
                completionHandler(TunnelLocalAuthIdentityError.superseded)
                return
            }
            let setLocal = { self.recoverySession.snapshot(ticket: sessionTicket)?.reconcileReadiness?() }

            let recoveryQueue = DispatchQueue(label: "network.ur.extension.destination-recovery", qos: .utility)
            let currentRecovery = { (ticket: RecoverySession.DestinationTicket) in
                ticket.session == sessionTicket && self.recoverySession.isCurrent(ticket)
                    && currentProvider() && self.isPacketReadActive(generation: packetReadGeneration)
            }
            let recoveryEffects = RecoveryEffects(
                enqueue: { action in recoveryQueue.async { action() } },
                schedule: { delay, fire in
                    let work = DispatchWorkItem(block: fire)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
                    return { work.cancel() }
                },
                now: { ProcessInfo.processInfo.systemUptime },
                minimumInterval: self.minimumTransportRecoveryInterval,
                isCurrent: currentRecovery,
                perform: { ticket, reasons in
                    self.completeDestinationRecovery(
                        device: device, providerTicket: providerTicket, ticket: ticket,
                        reasons: reasons, isCurrent: { currentRecovery(ticket) }
                    )
                }
            )
            let destinationRecovery = DestinationRecovery(
                enqueue: { action in recoveryQueue.async { action() } },
                scheduleDeadline: { expire in
                    let deadline = DispatchWorkItem(block: expire)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: deadline)
                    return { deadline.cancel() }
                },
                isCurrent: currentRecovery,
                observe: { ticket in
                    try self.reconcileIntendedDestinationIfNeeded(
                        device: device, ticket: ticket, isCurrent: { currentRecovery(ticket) },
                        restoreDestination: { try restoreDestinationOnce(ticket) }
                    )
                },
                completed: { ticket, reasons in
                    recoveryEffects.submit(ticket, reasons: reasons)
                },
                failed: { ticket in
                    DispatchQueue.main.async {
                        guard currentRecovery(ticket) else { return }
                        self.reasserting = true
                        self.recordRecoveryStage("destination", "failed")
                    }
                },
                report: { ticket, phase in
                    guard currentRecovery(ticket) else { return }
                    self.recordRecoveryStage("auth-observation", phase == .waiting ? "waiting" : "timeout")
                }
            )
            // Subscribe before publishing the request entry point. Healthy
            // refreshes only maintain the existing mirror; no pending request
            // means no recovery work. A failed mirror cannot lose settlement.
            let jwtRefreshSub = device.add(TunnelDeviceAuthSettlementObserver(
                device: device, isCurrent: currentProvider,
                settled: { destinationRecovery.settled() },
                accepted: { jwt in
                    if !SharedTunnelJwtStore.save(byJwt: jwt, instanceId: configuredInstanceId) {
                        self.logger.error("[PacketTunnelProvider]could not save refreshed shared tunnel JWT")
                    }
                }
            ))
            let recoveryLogoutSub = device.add(TunnelStartupAuthLogoutListener {
                destinationRecovery.cancel()
                recoveryEffects.cancel()
            })
            guard self.providerSessions.update(providerTicket, {
                $0.destinationRecovery = destinationRecovery
                $0.recoveryEffects = recoveryEffects
            }) else {
                destinationRecovery.cancel()
                recoveryEffects.cancel()
                jwtRefreshSub?.close()
                recoveryLogoutSub?.close()
                startupCleanup.cleanUpNow()
                completionHandler(TunnelLocalAuthIdentityError.superseded)
                return
            }

            let locationChangeSub = device.add(ConnectLocationChangeListener { _ in
                // Reserve the choice ticket at callback receipt, before main.
                guard let destinationTicket = self.recoverySession.noteDestinationChange(ticket: sessionTicket) else { return }
                destinationRecovery.retireStalePending()
                recoveryEffects.retireStalePending()
                DispatchQueue.main.async {
                    guard self.recoverySession.isCurrent(destinationTicket),
                          self.device === device, !device.getDone(), self.shouldSaveKeyMaterial else { return }
                    // Consume the current level, not a queued obsolete payload.
                    let location = device.getConnectLocation()
                    guard self.recoverySession.observeLocation(destinationTicket, present: location != nil, at: Date()) else { return }
                    if location == nil {
                        // An explicit live nil destination is local/disconnected,
                        // not a request to replay the same old connect intent.
                        do {
                            try self.recoverySession.observeIntentAfterLiveDisconnect(
                                destinationTicket, readIntent: { try TunnelIntentStore.loadChecked() }
                            )
                        } catch { self.recordRecoveryStage("intent-load", "failed") }
                    }
                    self.recoverySession.snapshot(ticket: sessionTicket)?.reconcileReadiness?()
                }
            })
            let localStateSaveSub = device.add(TunnelLocalStateSaveListener { result in
                guard let result, let state = self.recoverySession.snapshot(ticket: sessionTicket),
                      self.device === device, !device.getDone(), self.shouldSaveKeyMaterial else { return }
                // Consume this callback's immutable operation, not the last-result
                // getter, which a later mutation may already have replaced. The
                // SDK's fixed failure record also preserves its local sequence.
                let succeeded = reportTunnelPreferenceSave(
                    preference: result.getPreference(), autoSaveEnabled: result.getAutoSaveEnabled(),
                    saved: result.getSaved(), hasError: !result.getError().isEmpty,
                    report: { self.recordRecoveryStage($0, $1, snapshot: state) }
                )
                switch result.getPreference() {
                case "connect-location":
                    if succeeded {
                        self.recoverySession.savedLocationPersisted(state.destinationTicket)
                    }
                case "default-location":
                    if succeeded {
                        self.recoverySession.observeDefaultPreference(sessionTicket, unavailable: false)
                    }
                default:
                    break
                }
            })
            let keyPersistence = TunnelDeviceKeyPersistence(
                device: device, isCurrent: currentProvider,
                reportFailure: {
                    self.logger.error("[PacketTunnelProvider]failed to save device key material")
                }
            )
            let provideSecretKeysSub = device.add(keyPersistence)
            if let keyMaterial {
                device.setKeyMaterial(keyMaterial)
            }
            // persist the identity immediately: a freshly generated key must
            // survive this session even if no provide-key event fires, and a
            // loaded key must be re-written after a stale-state wipe
            keyPersistence.save()

            let provideChangeSub = device.add(ProvideChangeListener { provideEnabled in
                if provideEnabled && device.getConnectLocation() == nil {
                    DispatchQueue.main.async {
                        setLocal()
                    }
                }
            })
            // re-apply the network settings when the dns settings change the tunnel
            // dns servers (e.g. unencrypted local servers set or cleared)
            let dnsResolverSettingsChangeSub = device.add(DnsResolverSettingsChangeListener { _ in
                DispatchQueue.main.async {
                    guard self.device === device, !device.getDone() else { return }
                    self.applyTunnelNetworkSettings(device: device, providerTicket: providerTicket) { error in
                        if let error = error {
                            self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                        }
                    }
                }
            })
            let updateWindowStatus = { (_: SdkWindowStatus?) in self.recoverySession.snapshot(ticket: sessionTicket)?.reconcileReadiness?() }
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
            // Signature of the physical path (the tunnel's utun is .other, excluded
            // above). Compare only interfaces the path actually uses, not every
            // available interface in preference order. Commit a satisfied signature
            // only after it is stable so Wi-Fi/cellular transition bursts produce one
            // transport recovery at most. Mutable state is pathMonitorQueue-confined.
            var stablePathSignature: String? = nil
            var pathSignatureGeneration: UInt64 = 0
            var physicalPathWasUnavailable = false
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
                pathSignatureGeneration &+= 1
                let generation = pathSignatureGeneration
                guard path.status == .satisfied else {
                    // A Wi-Fi sleep/rejoin can return with the same interface and
                    // gateway. Remember the unavailable edge so signature equality
                    // cannot hide the fact that existing sockets crossed a dead path.
                    if stablePathSignature != nil {
                        physicalPathWasUnavailable = true
                    }
                    return
                }

                let interfaces = path.availableInterfaces
                    .filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.name):\($0.type)" }
                    .sorted()
                    .joined(separator: ",")
                let gateways = path.gateways
                    .map { "\($0)" }
                    .sorted()
                    .joined(separator: ",")
                let pathSignature = "interfaces=\(interfaces)|gateways=\(gateways)"

                pathMonitorQueue.asyncAfter(
                    deadline: .now() + self.transportRecoveryDebounce
                ) {
                    guard generation == pathSignatureGeneration else { return }
                    if let previous = stablePathSignature,
                       previous != pathSignature || physicalPathWasUnavailable {
                        let reason = physicalPathWasUnavailable
                            ? "physical-path-restored"
                            : "physical-path-change"
                        self.logger.info(
                            "[PacketTunnelProvider][\(self.lifecycleId)] stable physical path transition=\(reason); scheduling transport recovery"
                        )
                        self.requestTransportRecovery(reason: reason)
                    }
                    stablePathSignature = pathSignature
                    physicalPathWasUnavailable = false
                }
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
            // wake() refreshes path/power state. A stable signature change requests
            // one transport recovery; an unchanged healthy path remains untouched.
            let networkStateRefresh = {
                pathMonitorQueue.async {
                    handlePathUpdate(pathMonitor.currentPath)
                }
            }
            let provideNetworkModeChangeSub = device.add(ProvideNetworkModeChangeListener { _ in
                DispatchQueue.main.async {
                    updatePath(pathMonitor.currentPath)
                }
            })


    //        let packetWriteLock = NSLock()
            let packetReceiverSub = device.add(PacketBatchBytesReceiver { packetBatchBytes in
                packetOrigin.withActiveDevice(self.packetReads) { _ in
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
                            // Retired callbacks never decode/inject. Admission
                            // cannot preempt a write already in progress. This
                            // remains Connect's synchronous TUN receive exception;
                            // no native lock spans the NE write/Transfer handoff.
                            self.packetFlow.writePackets(packets, withProtocols: protocols)
                        }
                    }
                }
            })

            // publish location, providers, throughput and balance for the widgets
            let snapshotWriter = WidgetSnapshotWriter(device: device, logger: logger)
            snapshotWriter.start()

            let closeSession = {
                destinationRecovery.cancel()
                recoveryEffects.cancel()
                snapshotWriter.close()
                packetReceiverSub?.close()
                defaultPathObservation.invalidate()
                NotificationCenter.default.removeObserver(powerStateObserver)
                NotificationCenter.default.removeObserver(thermalStateObserver)
                self.recoverySession.retire(sessionTicket)
                pathMonitor.cancel()
                provideChangeSub?.close()
                provideSecretKeysSub?.close()
                jwtRefreshSub?.close()
                recoveryLogoutSub?.close()
                locationChangeSub?.close()
                localStateSaveSub?.close()
                dnsResolverSettingsChangeSub?.close()
                windowStatusChangeSub?.close()
                provideNetworkModeChangeSub?.close()
    //            packetContext.wrappingIncrement(ordering: .relaxed)
                startupCleanup.cleanUpNow()
            }
            guard self.providerSessions.update(providerTicket, {
                $0.close = closeSession
                $0.snapshotWriter = snapshotWriter
                $0.networkStateRefresh = networkStateRefresh
            }) else {
                closeSession()
                completionHandler(TunnelLocalAuthIdentityError.superseded)
                return
            }

            // Open RPC only after explicit Load, autosave, intent reconciliation and
            // observation/readiness listeners. Its first preference mutation cannot
            // predate autosave. Publish only the accepted client after RPC works.
            do {
                try finishTunnelLocalAuthSession(
                    configureRpc: {
                        try device.setRpcServer(rpcServerPem, clientCertPem: rpcClientPem, hostPort: rpcListenHostPort)
                    },
                    publishedClientJwt: { device.getClientJwt() },
                    publishClient: { publishedClientJwt in
                        deviceConfiguration["by_jwt"] = publishedClientJwt
                        guard self.providerSessions.update(providerTicket, { $0.configuration = deviceConfiguration }) else {
                            throw TunnelLocalAuthIdentityError.superseded
                        }
                        if !SharedTunnelJwtStore.save(byJwt: publishedClientJwt, instanceId: configuredInstanceId) {
                            self.recordRecoveryStage("auth-observation", "failed")
                        }
                    }
                )
                self.recordRecoveryStage("rpc", "completed")
            } catch {
                self.retireProviderSession(providerTicket).provider?.close?()
                completionHandler(error)
                return
            }

    //        Thread.setThreadPriority(1.0)
    //        self.setTunnelNetworkSettings(self.networkSettings()) { _ in
    ////            startPacketFlow()
    //            self.readToDevice()
    //            updateWindowStatus(device.getWindowStatus())
    //            completionHandler(nil)
    //        }

            self.applyTunnelNetworkSettings(device: device, providerTicket: providerTicket, force: true) { error in
                DispatchQueue.main.async {
                    guard self.isPacketReadActive(generation: packetReadGeneration) else {
                        completionHandler(NSError(domain: "network.ur.extension", code: 9, userInfo: [NSLocalizedDescriptionKey: "Tunnel start was superseded"]))
                        return
                    }

                    if let error {
                        self.logger.error("[PacketTunnelProvider]failed to set initial tunnel network settings: \(error.localizedDescription)")
                        if let close = self.retireProviderSession(providerTicket).provider?.close {
                            close()
                        } else {
                            startupCleanup.cleanUpNow()
                        }
                        completionHandler(error)
                        return
                    }

                    updateWindowStatus(device.getWindowStatus())
                    self.readToDevice(packetOrigin)
                    self.memoryMonitor?.sample(event: "tunnel-started")
                    guard self.providerSessions.update(providerTicket, { $0.started = true }) else {
                        completionHandler(TunnelLocalAuthIdentityError.superseded)
                        return
                    }
                    finishTunnelStartup(
                        recordOutcome: {
                            self.recordRecoveryStage("startup", "completed")
                        },
                        flushLogs: {
                            SdkFlushGlog()
                        },
                        completion: {
                            completionHandler(nil)
                        }
                    )
                    // the tunnel is up: re-render the quick connect control and
                    // the widgets now that NEVPNStatus reads connected
                    snapshotWriter.tunnelStarted()
                }
            }
        }

        let startupQueue = DispatchQueue(label: "network.ur.extension.auth-startup", qos: .utility)
        let failStartup = { (error: Error) in
            // Failure is delivered on startupQueue after admitted reads join.
            // Retirement already dispatches NE/settings callbacks to main;
            // SDK cleanup must not wait for a held main finish queue.
            let retiring = self.retireProviderSession(providerTicket).recovery
            if let retiring {
                if error is TunnelAuthStartupError { self.recordRecoveryStage("auth-observation", "timeout", snapshot: retiring) }
                self.recordRecoveryStage("startup", "failed", snapshot: retiring)
            }
            startupCleanup.cleanUpNow()
            completionHandler(error)
        }
        let startup = TunnelAuthStartupContinuation(
            enqueue: { work in startupQueue.async(execute: work) },
            subscribe: { settled, cancelled in
                let refresh = device.add(TunnelJwtRefreshListener { jwt in
                    guard let jwt, !jwt.isEmpty else { return }
                    settled()
                })
                let logout = device.add(TunnelStartupAuthLogoutListener { cancelled() })
                return { refresh?.close(); logout?.close() }
            },
            scheduleDeadline: { expired in
                let work = DispatchWorkItem(block: expired)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: work)
                return { work.cancel() }
            },
            isCurrent: {
                self.recoverySession.isCurrent(sessionTicket) && currentProvider()
                    && self.isPacketReadActive(generation: packetReadGeneration)
            },
            observe: restoreInitialPreferences,
            finishAdmission: self.recoverySession.startupFinishAdmission(
                ticket: sessionTicket,
                enqueue: { work in DispatchQueue.main.async(execute: work) },
                readIntent: readSharedIntent
            ),
            waiting: {
                if let state = self.recoverySession.snapshot(ticket: sessionTicket) {
                    self.recordRecoveryStage("auth-observation", "waiting", snapshot: state)
                }
            },
            completion: { result in
                self.recoverySession.clearAuthStartup(sessionTicket)
                switch result {
                case .success:
                    finishStartup()
                case .failure(let failure):
                    failStartup(failure)
                }
            }
        )
        guard recoverySession.installAuthStartup(startup, ticket: sessionTicket) else {
            startup.cancel()
            return
        }
        startup.start()
    }

    private func makeTunnelNetworkSettingsPlan(device: SdkDeviceLocal) -> TunnelNetworkSettingsPlan {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // IPv4 Configuration
        let tunnelLocalAddress = device.tunnelLocalAddress()
        let ipv4Settings = NEIPv4Settings(addresses: [tunnelLocalAddress], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        // exclude the local network from the tunnel, matching Android (MainService's
        // excludeRoute set): the RFC1918 private ranges bypass the tunnel so LAN
        // traffic reaches local devices directly. DNS is unaffected — it still routes
        // to the tunnel resolver via matchDomains below.
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        ]
        networkSettings.ipv4Settings = ipv4Settings

        // IPv6 Configuration: the tunnel is dual-stack (connect/IPV6.md C2).
        // The device's ULA tunnel address on its /64, the ::/0 default route,
        // and the same shape of exclusions as IPv4 (link-local, ULA, multicast,
        // loopback; see TunnelIpv6Routes.swift). Capturing ::/0 also closes the
        // bypass a dual-stack network had while the tunnel advertised no IPv6
        // interface: applications preferred the native IPv6 path around it.
        let tunnelLocalAddressIpv6 = device.tunnelLocalAddressIpv6()
        let ipv6Settings = NEIPv6Settings(
            addresses: [tunnelLocalAddressIpv6],
            networkPrefixLengths: [NSNumber(value: SdkGetTunnelLocalPrefixLengthIpv6())]
        )
        ipv6Settings.includedRoutes = [NEIPv6Route.default()]
        ipv6Settings.excludedRoutes = tunnelIpv6ExcludedRoutes().map { $0.neRoute }
        networkSettings.ipv6Settings = ipv6Settings

        // DNS from the SDK device: the dns settings' unencrypted local servers
        // when set, otherwise the distinct plain-DNS UpgradeMux mask (see
        // `tunnelDnsServers`), on both families. Always plain :53, never
        // OS-level encrypted DNS (DoH/DoT): the UpgradeMux claims :53 and
        // performs the unencrypted-DNS -> DoH upgrade itself, so enabling
        // encrypted DNS at the OS level here (e.g.
        // NEDNSOverHTTPSSettings/NEDNSOverTLSSettings) would bypass the mux
        // and hide queries from it.
        let dnsServers = self.tunnelDnsServers(device: device)
        if !dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: dnsServers)
            dnsSettings.matchDomains = [""]
            networkSettings.dnsSettings = dnsSettings
        }

        // The interface MTU (connect.DefaultTunnelMtu): 1280, the IPv6 minimum
        // link MTU, which the OS requires before it assigns an IPv6 address.
        // Packets stay within the smaller packet-size contract, so one full
        // encrypted tunnel packet still fits H3's single-DATAGRAM lane.
        let tunnelMtu = SdkGetDefaultTunnelMtu()
        networkSettings.mtu = NSNumber(value: tunnelMtu)

        let signature = tunnelNetworkSettingsSignature(
            ipv4Address: tunnelLocalAddress,
            ipv6Address: tunnelLocalAddressIpv6,
            dnsServers: dnsServers,
            mtu: tunnelMtu
        )
        return TunnelNetworkSettingsPlan(
            settings: networkSettings,
            signature: signature
        )
    }

    // A provider-owner admission may call preparation while holding that
    // owner lock. Detach callbacks/plans without applying NE settings, invoking
    // callbacks or releasing their captures until both locks are released.
    private struct TunnelSettingsSessionTransition {
        let callbacks: [((Error?) -> Void)]
        let retiredPlans: [TunnelNetworkSettingsPlan]
    }

    private func prepareTunnelSettingsSession(active: Bool) -> TunnelSettingsSessionTransition {
        tunnelSettingsLock.lock()
        tunnelSettingsGeneration &+= 1
        tunnelSettingsSessionActive = active
        appliedTunnelSettingsSignature = nil

        let callbacks = tunnelSettingsInFlightCompletions + pendingTunnelSettingsCompletions
        let retiredPlans = [tunnelSettingsInFlight, pendingTunnelSettings].compactMap { $0 }
        tunnelSettingsInFlight = nil
        tunnelSettingsInFlightCompletions = []
        pendingTunnelSettings = nil
        pendingTunnelSettingsForce = false
        pendingTunnelSettingsCompletions = []
        tunnelSettingsLock.unlock()
        return TunnelSettingsSessionTransition(callbacks: callbacks, retiredPlans: retiredPlans)
    }

    private func completeTunnelSettingsTransition(_ transition: TunnelSettingsSessionTransition?, errorDescription: String) {
        guard let transition, !transition.callbacks.isEmpty else { return }
        let error = NSError(
            domain: "network.ur.extension",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: errorDescription]
        )
        completeTunnelSettingsCallbacks(transition.callbacks, error: error)
        withExtendedLifetime(transition.retiredPlans) {}
    }

    // The provider ticket, not a settings transaction generation, owns all
    // session retirement. Preparation is callback-free; cancellation and NE
    // completion delivery occur after the provider owner releases its lock.
    private func retireProviderSession(
        _ ticket: TunnelProviderSessionOwner<ProviderSession>.Ticket? = nil
    ) -> (provider: ProviderSession?, recovery: RecoverySession.Snapshot?) {
        var recovery: RecoverySession.Snapshot?
        var settings: TunnelSettingsSessionTransition?
        let provider = providerSessions.take(ticket, prepareWithLock: {
            self.stopPacketReads()
            settings = self.prepareTunnelSettingsSession(active: false)
            recovery = self.recoverySession.prepareRetire()
        })
        provider?.destinationRecovery?.cancel()
        provider?.recoveryEffects?.cancel()
        recoverySession.completeRetirement(recovery)
        completeTunnelSettingsTransition(settings, errorDescription: "Tunnel network settings session stopped")
        return (provider, recovery)
    }

    /**
     * Apply at most one NEPacketTunnelNetworkSettings transaction at a time.
     * Equal settings join the active transaction; if settings change while it
     * is active, only the newest plan is retained and applied next.
     */
    private func applyTunnelNetworkSettings(
        device: SdkDeviceLocal, providerTicket: TunnelProviderSessionOwner<ProviderSession>.Ticket,
        force: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        // All SDK reads use one retained origin, before either native lock.
        let plan = makeTunnelNetworkSettingsPlan(device: device)
        var start: (TunnelNetworkSettingsPlan, UInt64)?
        var inactive = false
        var completeImmediately = false
        var retainedCallbacks: [((Error?) -> Void)] = []
        var retainedPlans: [TunnelNetworkSettingsPlan] = []
        let admitted = providerSessions.admitPrepared(providerTicket) {
            // Same lock order as provider publication/retirement. Retain all
            // replaced captures until both locks are released.
            tunnelSettingsLock.lock()
            retainedCallbacks = tunnelSettingsInFlightCompletions + pendingTunnelSettingsCompletions
            retainedPlans = [tunnelSettingsInFlight, pendingTunnelSettings].compactMap { $0 }
            if !tunnelSettingsSessionActive {
                inactive = true
            } else if let inFlight = tunnelSettingsInFlight {
                if inFlight.signature == plan.signature {
                    // Latest state has returned to the plan already in flight.
                    // Cancel a different pending plan and join this transaction.
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
        }
        withExtendedLifetime((retainedCallbacks, retainedPlans)) {}

        if !admitted || inactive {
            if let completion {
                completeTunnelSettingsCallbacks([completion], error: TunnelLocalAuthIdentityError.superseded)
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
    /// The tunnel is dual-stack, so the ipv4 resolvers come first and the ipv6
    /// resolvers follow; both route into the tunnel (the ipv6 exclusions leave
    /// the resolver prefix alone).
    private func tunnelDnsServers(device: SdkDeviceLocal) -> [String] {
        var servers: [String] = []
        for addresses in [device.tunnelDnsAddressesIpv4(), device.tunnelDnsAddressesIpv6()] {
            guard let addresses else {
                continue
            }
            for i in 0..<addresses.len() {
                servers.append(addresses.get(i))
            }
        }
        return tunnelOwnedDnsServers(
            interceptorPresent: device.getTunnelDnsInterceptorActive(),
            advertised: servers
        )
    }

    private func reconcileIntendedDestinationIfNeeded(
        device: SdkDeviceLocal, ticket: RecoverySession.DestinationTicket,
        isCurrent: () -> Bool, restoreDestination: () throws -> Void
    ) throws {
        guard isCurrent(), let state = recoverySession.snapshot(ticket: ticket.session),
              state.destinationTicket == ticket else { throw TunnelLocalAuthIdentityError.superseded }
        let sharedIntent: TunnelIntent?
        do {
            sharedIntent = try TunnelIntentStore.loadChecked()
            recordRecoveryStage("intent-load", sharedIntent == nil ? "missing" : "present")
        } catch {
            recordRecoveryStage("intent-load", "failed")
            throw error
        }
        let hasNewCurrentIntent = sharedIntent != state.observedIntent
            && (sharedIntent?.applies(to: state.owner) ?? false)
            && (sharedIntent.map { !$0.connect || tunnelConnectIntentIsNewer(changedAt: $0.changedAt, liveDisconnectAt: state.liveDisconnectAt) } ?? false)
        let missingIntendedConsumer = state.connectIntended
            && (device.getConnectLocation() == nil || !device.getConnectEnabled())
        if hasNewCurrentIntent || missingIntendedConsumer {
            guard isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
            try restoreDestination()
        }
    }

    // Called only by the serial recovery worker. Network operations remain
    // outside the main/lifecycle queues and all native locks. The original
    // destination must still own effects after an admitted SDK call returns.
    private func completeDestinationRecovery(
        device: SdkDeviceLocal, providerTicket: TunnelProviderSessionOwner<ProviderSession>.Ticket,
        ticket: RecoverySession.DestinationTicket, reasons: TunnelDestinationRecoveryReason,
        isCurrent: @escaping () -> Bool
    ) {
        guard isCurrent() else { return }
        let recoveryStartedAt = Date()
        if reasons.contains(.path) {
            device.networkChanged()
        }
        guard isCurrent() else { return }
        if !reasons.intersection([.wake, .wakeGrace]).isEmpty {
            _ = device.probeAllExits()
        }
        DispatchQueue.main.async {
            guard isCurrent() else { return }
            if reasons.contains(.path) {
                self.lastTransportRecoveryAt = recoveryStartedAt
                self.memoryMonitor?.sample(event: "transport-recovery")
                self.recordRecoveryStage("path-recovery", "completed")
            }
            self.recoverySession.snapshot(ticket: ticket.session)?.reconcileReadiness?()
            if reasons.contains(.wake) {
                self.scheduleWakeHealthCheck(
                    device: device, providerTicket: providerTicket, ticket: ticket,
                    wakeStartedAt: recoveryStartedAt
                )
            }
        }
    }

    // Sparse transition breadcrumbs share the existing SDK/glog export path.
    // The SDK validates the vocabulary and clamps counters; no error text,
    // auth bytes, path, address or peer identifier is accepted here.
    private func recordRecoveryStage(_ stage: String, _ result: String) {
        recordRecoveryStage(stage, result, snapshot: recoverySession.snapshot())
    }

    private func recordRecoveryStage(
        _ stage: String, _ result: String, snapshot state: RecoverySession.Snapshot?
    ) {
        let diagnostics = state?.readDiagnostics?()
        let intended = state?.connectIntended ?? false
        let consumer = diagnostics?.consumerPresent ?? false
        let location = diagnostics?.hasLocation ?? false
        let providers = diagnostics?.providerCount ?? -1
        let generation = Int64(min(state?.readiness.generation ?? 0, UInt64(Int64.max)))
        let fingerprint = "\(result)|\(intended)|\(consumer)|\(location)|\(providers)|\(generation)"
        recoveryBreadcrumbLock.lock()
        let duplicate = recoveryBreadcrumbs[stage] == fingerprint
        recoveryBreadcrumbs[stage] = fingerprint
        recoveryBreadcrumbLock.unlock()
        guard !duplicate else { return }
        let line = SdkRecordTunnelRecoveryStage(stage, result, intended, consumer, location, providers, generation)
        logger.info("\(line, privacy: .public)")
    }

    private func requestTransportRecovery(reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.scheduleTransportRecovery(reason: reason)
        }
    }

    private func scheduleTransportRecovery(reason: String, changeTransport: Bool = true) {
        guard let provider = providerSessions.snapshot(), !provider.value.device.getDone() else { return }
        let device = provider.value.device
        // A settings retry can share the existing debounce but cannot erase a
        // real pending path recovery or reset otherwise healthy transports.
        recoveryNeedsTransportChange = recoveryNeedsTransportChange || changeTransport

        // Burst coalescing precedes observation. The final-effects owner uses
        // a monotonic clock for the sole two-second reset admission check.
        let delay = transportRecoveryDebounce

        transportRecoveryWork?.cancel()
        recoveryWorkGeneration &+= 1
        let generation = recoveryWorkGeneration
        let work = DispatchWorkItem { [weak self, weak device] in
            guard let self,
                  let device,
                  self.providerSessions.snapshot(ticket: provider.ticket)?.value.device === device,
                  self.recoveryWorkGeneration == generation,
                  !device.getDone() else {
                return
            }
            self.transportRecoveryWork = nil
            let changeTransport = self.recoveryNeedsTransportChange
            self.recoveryNeedsTransportChange = false
            self.recordRecoveryStage(changeTransport ? "path-recovery" : "settings", changeTransport ? "started" : "retry")
            if changeTransport {
                guard let state = self.recoverySession.snapshot(),
                      let recovery = self.providerSessions.snapshot(ticket: provider.ticket)?.value.destinationRecovery else { return }
                recovery.request(state.destinationTicket, reason: .path)
                return
            }
            do {
                try performTunnelRecovery(
                    changeTransport: false,
                    isCurrent: { self.device === device && !device.getDone() && self.recoveryWorkGeneration == generation },
                    restoreDestination: {},
                    networkChanged: {},
                    reconcileReadiness: { self.recoverySession.snapshot()?.reconcileReadiness?() }
                )
            } catch {
                self.reasserting = true
                self.recordRecoveryStage("settings", "failed")
            }
        }
        transportRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingTransportRecovery() {
        transportRecoveryWork?.cancel()
        transportRecoveryWork = nil
        recoveryWorkGeneration &+= 1
        recoveryNeedsTransportChange = false
        wakeHealthWork?.cancel()
        wakeHealthWork = nil
    }

    private func refreshAndProbeAfterWake() {
        guard let provider = providerSessions.snapshot(),
              let recovery = provider.value.destinationRecovery,
              !provider.value.device.getDone(), let state = recoverySession.snapshot() else { return }
        recordRecoveryStage("wake", "started")
        provider.value.networkStateRefresh?()
        recovery.request(state.destinationTicket, reason: .wake)
    }

    private func scheduleWakeHealthCheck(
        device: SdkDeviceLocal, providerTicket: TunnelProviderSessionOwner<ProviderSession>.Ticket,
        ticket: RecoverySession.DestinationTicket, wakeStartedAt: Date
    ) {
        wakeHealthWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak device] in
            guard let self,
                  let device,
                  self.providerSessions.snapshot(ticket: providerTicket)?.value.device === device,
                  self.recoverySession.isCurrent(ticket),
                  !device.getDone() else {
                return
            }
            self.wakeHealthWork = nil

            guard let state = self.recoverySession.snapshot(ticket: ticket.session) else { return }
            let providerCount = device.getWindowStatus()?.providerStateAdded ?? 0
            let action = tunnelWakeAction(
                connectIntended: state.connectIntended,
                destinationPresent: device.getConnectLocation() != nil,
                consumerPresent: device.getConnectEnabled(),
                providerCount: providerCount, afterGrace: true,
                pathRecoveryAlreadyRequested: self.lastTransportRecoveryAt.map { $0 >= wakeStartedAt } ?? false
            )
            switch action {
            case .restoreDestination:
                self.providerSessions.snapshot(ticket: providerTicket)?.value.destinationRecovery?
                    .request(state.destinationTicket, reason: .wakeGrace)
            case .coveredByPathRecovery:
                self.logger.info(
                    "[PacketTunnelProvider][\(self.lifecycleId)] wake health covered by path recovery"
                )
            case .local:
                self.recordRecoveryStage("wake", "local")
                self.logger.info(
                    "[PacketTunnelProvider][\(self.lifecycleId)] wake healthy local mode"
                )
            case .probeExisting:
                self.recordRecoveryStage("wake", "present")
                self.logger.info(
                    "[PacketTunnelProvider][\(self.lifecycleId)] wake window present providers=\(providerCount)"
                )
            case .recoverTransport:
                self.recordRecoveryStage("wake", "empty-window")
                self.scheduleTransportRecovery(reason: "wake-unhealthy")
            }
        }
        wakeHealthWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + wakeHealthGrace,
            execute: work
        )
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("[PacketTunnelProvider][\(self.lifecycleId)] stop reason=\(String(describing: reason))")
        let reasonKind: TunnelStopReasonKind
        switch reason {
        case .userInitiated, .providerDisabled, .configurationDisabled, .configurationRemoved:
            reasonKind = .userDisabled
        case .superceded:
            reasonKind = .superseded
        case .appUpdate:
            reasonKind = .appUpdate
        case .providerFailed, .connectionFailed, .configurationFailed, .authenticationCanceled:
            reasonKind = .failure
        default:
            reasonKind = .other
        }
        let reasonClass = tunnelStopReasonClass(reasonKind)
        var retiringProvider: ProviderSession?
        var retiringState: RecoverySession.Snapshot?
        finishTunnelStop(
            cleanup: {
                let retirement = self.retireProviderSession()
                retiringProvider = retirement.provider
                retiringState = retirement.recovery
                self.recordRecoveryStage("stop", reasonClass, snapshot: retiringState)
                self.memoryMonitor?.sample(event: "tunnel-stopping")
                DispatchQueue.main.async { [weak self] in
                    self?.cancelPendingTransportRecovery()
                }

                self.recordSharedIntentForStop(reason: reason, owner: retiringState?.owner)
                if let snapshotWriter = retiringProvider?.snapshotWriter {
                    // writes the widgets' snapshot as inactive and re-renders the
                    // control and widgets; synchronous, since this process may be
                    // reaped as soon as the completion handler runs
                    snapshotWriter.tunnelStopped()
                }

                if let close = retiringProvider?.close {
                    close()
                } else {
                    retiringProvider?.device.close()
                }
            },
            joinCleanup: {
                retiringProvider?.device.wait(forClose: tunnelStopCloseJoinTimeoutMilliseconds) ?? true
            },
            reportCleanupJoin: { joined in
                self.recordRecoveryStage("stop", joined ? "completed" : "timeout", snapshot: retiringState)
            },
            sampleFinalState: {
                self.memoryMonitor?.sample(event: "tunnel-stopped")
            },
            flushLogs: {
                SdkFlushGlog()
            },
            completion: completionHandler
        )
    }

    /// A stop the user made outside the app (Settings > VPN, the system's VPN
    /// control, or another VPN taking over) is a disconnect the app must not
    /// undo on its next foreground. The app marks the stops it makes itself
    /// (TunnelIntentStore.markAppInitiatedStop) so they are not mistaken for
    /// one; the quick connect control records its own intent before stopping.
    private func recordSharedIntentForStop(reason: NEProviderStopReason, owner: TunnelIntentOwner?) {
        let appInitiated = TunnelIntentStore.consumeAppInitiatedStop()
        switch reason {
        case .userInitiated, .configurationDisabled, .providerDisabled, .superceded:
            guard !appInitiated else { return }
            if let current = TunnelIntentStore.load(),
               !current.connect,
               Date().timeIntervalSince(current.changedAt) < TunnelIntentStore.appStopWindow {
                // the control or the widget already recorded this disconnect
                return
            }
            TunnelIntentStore.record(connect: false, source: TunnelIntentStore.sourceSystem, owner: owner)
            logger.info("[PacketTunnelProvider][\(self.lifecycleId)] recorded a system disconnect intent")
        default:
            return
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        lifecycleLock.lock()
        sleepStartedAt = Date()
        lifecycleLock.unlock()

        logger.info("[PacketTunnelProvider][\(self.lifecycleId)] sleep")
        memoryMonitor?.sample(event: "sleep")
        DispatchQueue.main.async { [weak self] in
            self?.cancelPendingTransportRecovery()
        }
        // Keep the SDK device and its transports intact. Its scheduler-pause
        // detector rebases liveness clocks when execution resumes.
        completionHandler()
    }

    override func wake() {
        lifecycleLock.lock()
        let sleepDuration = sleepStartedAt.map {
            Date().timeIntervalSince($0)
        }
        sleepStartedAt = nil
        lifecycleLock.unlock()

        logger.info(
            "[PacketTunnelProvider][\(self.lifecycleId)] wake sleptSeconds=\(sleepDuration ?? 0)"
        )
        memoryMonitor?.sample(event: "wake")
        DispatchQueue.main.async { [weak self] in
            self?.refreshAndProbeAfterWake()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(data: messageData, encoding: .utf8) == flushLogsProviderMessage {
            // glog buffers each severity file through a 256KiB writer and
            // flushes on a 30s ticker, and the zip is assembled in the app
            // process -- so without this the last seconds of extension logs,
            // the ones describing whatever the user is reporting, are still in
            // this process's memory when the app reads the files.
            SdkFlushGlog()
            completionHandler?(Data("ok".utf8))
            return
        }

        if String(data: messageData, encoding: .utf8) == logoutProviderMessage {
            var retiringState: RecoverySession.Snapshot?
            var retiringSettings: TunnelSettingsSessionTransition?
            do {
                try providerSessions.withLogout(prepareWithLock: {
                    self.stopPacketReads()
                    retiringSettings = self.prepareTunnelSettingsSession(active: false)
                    retiringState = self.recoverySession.prepareRetire()
                }, clear: { provider in
                    // New starts reject until these outside-lock clears finish.
                    // A missing published LocalState does not skip shared logout.
                    provider?.destinationRecovery?.cancel()
                    provider?.recoveryEffects?.cancel()
                    self.recoverySession.completeRetirement(retiringState)
                    self.completeTunnelSettingsTransition(retiringSettings, errorDescription: "Tunnel network settings session stopped")
                    defer {
                        if let close = provider?.close { close() }
                        else { provider?.device.close() }
                    }
                    TunnelIntentStore.record(connect: false, source: TunnelIntentStore.sourceApp, owner: retiringState?.owner)
                    SharedTunnelJwtStore.clear()
                    try provider?.localState.logout()
                })
                completionHandler?(Data("ok".utf8))
            } catch {
                logger.error("[PacketTunnelProvider]failed to clear local state on logout")
                completionHandler?(Data("error".utf8))
            }
            return
        }

        if let handler = completionHandler {
            handler(messageData)
        }
    }


    private func beginPacketReads() -> UInt64 {
        packetReads.begin()
    }

    private func stopPacketReads(generation: UInt64? = nil) {
        packetReads.stop(generation: generation)
    }

    private func isPacketReadActive(generation: UInt64) -> Bool {
        packetReads.isActive(generation: generation)
    }

    private func readToDevice(_ origin: TunnelPacketReadOrigin<SdkDeviceLocal>) {
        guard isPacketReadActive(generation: origin.generation) else { return }

        self.packetFlow.readPackets { packets, protocols in
            origin.withActiveDevice(self.packetReads) { device in
                TunnelPacketBatchCodec.encode(packets) { packetBatchBytes in
                    autoreleasepool {
                        _ = device.sendPacketBatch(packetBatchBytes)
                    }
                }
            }
            self.readToDevice(origin)
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


private final class TunnelStartupAuthLogoutListener: NSObject, SdkAuthLogoutListenerProtocol {
    private let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func authLogout() { callback() }
}

private final class TunnelLocalStateSaveListener: NSObject, SdkLocalStateSaveListenerProtocol {
    private let callback: (SdkDeviceLocalSaveResult?) -> Void

    init(_ callback: @escaping (SdkDeviceLocalSaveResult?) -> Void) {
        self.callback = callback
    }

    func localStateSaved(_ result: SdkDeviceLocalSaveResult?) {
        callback(result)
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
