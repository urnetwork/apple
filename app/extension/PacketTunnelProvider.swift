//
//  PacketTunnelProvider.swift
//  network
//
//  Created by Stuart Kuentzel on 2024/12/24.
//

import NetworkExtension
import URnetworkSdk
import OSLog

//import Atomics

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
    private var connected: Bool = false
    // the dns servers currently applied to the tunnel, used to detect when the
    // network settings need a re-apply after a dns settings change
    private var appliedTunnelDnsServers: [String] = []
    private var stopped: Bool = false
    private var shouldSaveKeyMaterial: Bool = true
    private let packetReadLock = NSLock()
    private var packetReadGeneration: UInt64 = 0
    private let logoutProviderMessage = "logout"


    override init() {
        super.init()

        logger.info("[PacketTunnelProvider]init")

        if #available(iOS 26, macOS 26, *) {
            // the memory limit in the PacketTunnelProvider is 50mib in iOS 16, 17, 18, 26
            // the binary and go runtime take about 16mib of that
            // see https://forums.developer.apple.com/forums/thread/73148?page=2
#if os(iOS)
            SdkSetMemoryLimit(24 * 1024 * 1024)
#else
            SdkSetMemoryLimit(64 * 1024 * 1024)
#endif
        } else if #available(iOS 16, macOS 13, *) {
            #if os(iOS)
            SdkSetMemoryLimit(24 * 1024 * 1024)
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
            memoryPressureSource.setEventHandler {
                let event = DispatchSource.MemoryPressureEvent(rawValue: memoryPressureSource.data)
                if event.contains(.warning) || event.contains(.critical) {
                    SdkFreeMemory()
                }
            }
            memoryPressureSource.activate()
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }


    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping ((any Error)?) -> Void) {
        logger.info("[PacketTunnelProvider]start")

        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            logger.error( "[PacketTunnelProvider]start failed - no providerConfiguration")
            completionHandler(NSError(domain: "network.ur.extension", code: 1, userInfo: [NSLocalizedDescriptionKey: "No provider configuration"]))
            return
        }


        guard let byJwt = providerConfiguration["by_jwt"] as? String else {
            completionHandler(NSError(domain: "network.ur.extension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing by_jwt"]))
            return
        }

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

        let instanceId = SdkParseId(providerConfiguration["instance_id"] as? String, &err)
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


//        self.reasserting = true


        // create new device with latest config
        
        self.connected = false
        self.close?()
        self.close = nil
        


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

        let newDevice = SdkNewDeviceLocalWithKeyMaterial(
            networkSpace,
            byJwt,
            "ios-network-extension",
            deviceModel() ?? "ios-unknown",
            "\(appVersionString)-\(buildNumber)",
            instanceId,
            // rpc is started explicitly below with the per-session server pem
            false,
            keyMaterial,
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

        // start the rpc server listening on the per-session host/port,
        // presenting the self-signed server certificate and requiring + pinning
        // the client certificate (mTLS) from the app
        do {
            try device.setRpcServer(rpcServerPem, clientCertPem: rpcClientPem, hostPort: rpcListenHostPort)
        } catch {
            completionHandler(error)
            return
        }

        
        let packetReadGeneration = self.beginPacketReads()
        self.reasserting = true

        // a stale auth state wipes the session state below, but never the
        // device identity: the loaded key material is re-persisted after the
        // wipe (see saveKeyMaterial() at the end of setup)
        prepareLocalStateForStart(localState, byJwt: byJwt, instanceId: instanceId, hasStaleLocalState: localStateIsStale)

        self.deviceConfiguration = deviceConfiguration
        self.device = device
        self.localState = localState
        self.shouldSaveKeyMaterial = true

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
                self.setTunnelNetworkSettings(self.networkSettings()) { error in
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
                if self.tunnelDnsServers() != self.appliedTunnelDnsServers {
                    self.setTunnelNetworkSettings(self.networkSettings()) { error in
                        if let error = error {
                            self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                        }
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
                    self.setTunnelNetworkSettings(self.networkSettings()) { error in
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
                updateWindowStatus(device.getWindowStatus())
            }
        })

        let updatePath = { (path: Network.NWPath) in
            let canProvideOnCell = device.getProvideNetworkMode() == "all"
            let canProvideOnNetwork = canProvideOnNetwork(path: path, canProvideOnCell: canProvideOnCell)
            self.logger.info("[PacketTunnelProvider]provider network update cell=\(canProvideOnCell) provide=\(canProvideOnNetwork)")
            device.setProvidePaused(!canProvideOnNetwork)
        }
        let pathMonitor = NWPathMonitor.init(prohibitedInterfaceTypes: [.loopback, .other])
        let pathMonitorQueue = DispatchQueue(label: "network.ur.extension.pathMonitor")
        pathMonitor.pathUpdateHandler = { path in
            updatePath(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
        let provideNetworkModeChangeSub = device.add( ProvideNetworkModeChangeListener { mode in
            if let mode {
                try? localState.setProvideNetworkMode(mode)
            }
            DispatchQueue.main.async {
                updatePath(pathMonitor.currentPath)
            }
        })


//        let packetWriteLock = NSLock()
        let packetReceiverSub = device.add(PacketReceiver { ipVersion, ipProtocol, packet in
//            let dataCopy = try! data.withUnsafeBytes<Data> { body in
//                return Data(bytes: body, count: data.count)
//            }

//            packetWriteLock.lock()
//            defer { packetWriteLock.unlock() }

            switch ipVersion {
            case 4:
                self.packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
            case 6:
                self.packetFlow.writePackets([packet], withProtocols: [AF_INET6 as NSNumber])
            default:
                // unknown version, drop
                break
            }
        })

        self.close = {
            packetReceiverSub?.close()
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
            locationChangeSub?.close()
            defaultLocationChangeSub?.close()
            dnsResolverSettingsChangeSub?.close()
            windowStatusChangeSub?.close()
            provideNetworkModeChangeSub?.close()
//            packetContext.wrappingIncrement(ordering: .relaxed)
            device.close()
        }

//        Thread.setThreadPriority(1.0)
//        self.setTunnelNetworkSettings(self.networkSettings()) { _ in
////            startPacketFlow()
//            self.readToDevice()
//            updateWindowStatus(device.getWindowStatus())
//            completionHandler(nil)
//        }

        self.setTunnelNetworkSettings(self.networkSettings()) { error in
            DispatchQueue.main.async {
                guard self.isPacketReadActive(generation: packetReadGeneration) else {
                    completionHandler(NSError(domain: "network.ur.extension", code: 9, userInfo: [NSLocalizedDescriptionKey: "Tunnel start was superseded"]))
                    return
                }

                if let error {
                    self.logger.error("[PacketTunnelProvider]failed to set initial tunnel network settings: \(error.localizedDescription)")
                    self.stopPacketReads()
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
                completionHandler(nil)
            }
        }
    }

    func networkSettings() -> NEPacketTunnelNetworkSettings {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // IPv4 Configuration
        let tunnelLocalAddress = self.device?.tunnelLocalAddress() ?? "169.254.2.1"
        let ipv4Settings = NEIPv4Settings(addresses: [tunnelLocalAddress], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        // exclude the local network from the tunnel, matching Android (MainService's
        // excludeRoute set): the RFC1918 private ranges bypass the tunnel so LAN
        // traffic reaches local devices directly. DNS is unaffected — it still routes
        // to the tunnel resolver via matchDomains below (the ipv6 tunnel carries no
        // routes, so ipv6 ULA fd00::/8 already bypasses without an explicit exclude).
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        ]
        networkSettings.ipv4Settings = ipv4Settings

        let ipv6Settings = NEIPv6Settings()
        networkSettings.ipv6Settings = ipv6Settings

        // DNS from the SDK device, like the tunnel address: the dns settings'
        // unencrypted local servers when set, otherwise the default plain-DNS
        // resolvers (see `tunnelDnsServers`). Always plain :53, never OS-level
        // encrypted DNS (DoH/DoT): the UpgradeMux claims :53 and performs the
        // unencrypted-DNS -> DoH upgrade itself, so enabling encrypted DNS at the OS
        // level here (e.g. NEDNSOverHTTPSSettings/NEDNSOverTLSSettings) would bypass
        // the mux and hide queries from it.
        let dnsServers = self.tunnelDnsServers()
        self.appliedTunnelDnsServers = dnsServers
        let dnsSettings = NEDNSSettings(servers: dnsServers)
        // route every DNS query to the tunnel resolver (empty string matches all
        // domains). without this the OS may not send :53 queries into the tunnel, so
        // the UpgradeMux never sees them and resolution fails.
        dnsSettings.matchDomains = [""]
        networkSettings.dnsSettings = dnsSettings

        // default URnetwork MTU
        networkSettings.mtu = 1440

        return networkSettings
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
            // static fallback matching the SDK default tunnel resolvers; Quad9
            // (9.9.9.9) leads so no resolver the OS would auto-upgrade to encrypted
            // DNS is applied alone (see the SDK's defaultTunnelDnsServersIpv4)
            servers = ["9.9.9.9", "1.1.1.1"]
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

        self.stopPacketReads()
        if let close = self.close {
            close()
            self.close = nil
        } else {
            self.device?.close()
        }
        self.device = nil
        self.localState = nil
        self.shouldSaveKeyMaterial = true
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(data: messageData, encoding: .utf8) == logoutProviderMessage {
            shouldSaveKeyMaterial = false
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
                for packet in packets {
                    device.sendPacket(packet, n: Int32(packet.count))
                }
            }
            self.readToDevice(generation: generation)
        }
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




private class PacketReceiver: NSObject, SdkReceivePacketProtocol {
    func receivePacket(_ ipVersion: Int, ipProtocol: Int, packet: Data?) {
        if let packet {
            c(ipVersion, ipProtocol, packet)
        }
    }

    private let c: (Int, Int, Data) -> Void

    init(c: @escaping (Int, Int, Data) -> Void) {
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
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return true
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
