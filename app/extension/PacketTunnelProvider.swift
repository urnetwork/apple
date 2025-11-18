//
//  PacketTunnelProvider.swift
//  network
//
//  Created by Stuart Kuentzel on 2024/12/24.
//

import NetworkExtension
import URnetworkSdk
import OSLog

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
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var connected: Bool = false

    
    override init() {
        super.init()
        
        logger.info("[PacketTunnelProvider]init")
        
        if #available(iOS 16, macOS 13, *) {
            // the memory limit in the PacketTunnelProvider is 50mib in iOS 16, 17, 18
            // the binary and go runtime take about 20mib of that, leaving at most about 30mib for the sdk and tunnel provider
            // since the limit is a soft limit, take ~80% of the available for the SDK
            // see https://forums.developer.apple.com/forums/thread/73148?page=2
            #if os(iOS)
            SdkSetMemoryLimit(32 * 1024 * 1024)
            #else
            SdkSetMemoryLimit(64 * 1024 * 1024)
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
                switch memoryPressureSource.mask {
                case DispatchSource.MemoryPressureEvent.normal:
                    //                SdkFreeMemory()
                    break
                case DispatchSource.MemoryPressureEvent.warning:
                    SdkFreeMemory()
                case DispatchSource.MemoryPressureEvent.critical:
                    SdkFreeMemory()
                default:
                    break
                }
                
            }
            memoryPressureSource.activate()
        }
    }
    
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping ((any Error)?) -> Void) {
        logger.info("[PacketTunnelProvider]start")
        
        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            logger.error( "[PacketTunnelProvider]start failed - no providerConfiguration")
            completionHandler(nil)
            return
        }
        
        
        guard let byJwt = providerConfiguration["by_jwt"] as? String else {
            completionHandler(nil)
            return
        }
        
        guard let networkSpaceJson = providerConfiguration["network_space"] as? String else {
            completionHandler(nil)
            return
        }
        
        guard let rpcPublicKey = providerConfiguration["rpc_public_key"] as? String else {
            completionHandler(nil)
            return
        }
        
        
        var err: NSError?
        
        let instanceId = SdkParseId(providerConfiguration["instance_id"] as? String, &err)
        if let err {
            completionHandler(err)
            return
        }
        guard let instanceId = instanceId else {
            completionHandler(nil)
            return
        }
        
        
        let deviceConfiguration = [
            "by_jwt": byJwt,
            "network_space": networkSpaceJson,
            "rpc_public_key": rpcPublicKey,
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
        self.reasserting = true
        
        self.device?.cancel()
        self.device = nil
        
        self.deviceConfiguration = deviceConfiguration
        
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
            completionHandler(nil)
            return
        }
        
        guard let localState = networkSpace.getAsyncLocalState()?.getLocalState() else {
            completionHandler(nil)
            return
        }
        
        let appVersionString: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        let buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String

        self.device = SdkNewDeviceLocalWithDefaults(
            networkSpace,
            byJwt,
            "ios-network-extension",
            deviceModel() ?? "ios-unknown",
            "\(appVersionString)-\(buildNumber)",
            instanceId,
            true,
            &err
        )
        if let err {
            completionHandler(err)
            return
        }
        
        
        guard let device = self.device else {
            completionHandler(nil)
            return
        }
        
        
        
        
        // load initial device settings
        // these will be in effect until the app connects and sets the user values
        device.setTunnelStarted(true)
        device.setProvidePaused(true)
        if let location = localState.getConnectLocation() {
            device.setConnectLocation(location)
        }
        device.setProvideMode(localState.getProvideMode())
        device.setRouteLocal(localState.getRouteLocal())
        
        let setLocal = {
            if device.getConnectLocation() == nil {
                // reset to local if available
                self.setTunnelNetworkSettings(self.networkSettings()) { error in
                    if let error = error {
                        self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                        return
                    }
                    self.reasserting = device.getConnectLocation() != nil
                    readToDevice(packetFlow: self.packetFlow, device: device)
                }
            }
        }
        
        let locationChangeSub = device.add(ConnectLocationChangeListener { location in
            try? localState.setConnectLocation(location)
            
            if location == nil {
                DispatchQueue.main.async {
                    setLocal()
                }
            }
        })
        let provideChangeSub = device.add(ProvideChangeListener { provideEnabled in
            var provideMode: Int
            if provideEnabled {
                provideMode = SdkProvideModePublic
            } else {
                provideMode = SdkProvideModeNone
            }
            try? localState.setProvideMode(provideMode)
            
            if provideEnabled {
                DispatchQueue.main.async {
                    setLocal()
                }
            }
        })
        let routeLocalChangeSub = device.add(RouteLocalChangeListener { routeLocal in
            try? localState.setRouteLocal(routeLocal)
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
                        self.setTunnelNetworkSettings(self.networkSettings()) { error in
                            if let error = error {
                                self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                                return
                            }
                            readToDevice(packetFlow: self.packetFlow, device: device)
                        }
                    }
                } else {
                    self.setTunnelNetworkSettings(self.networkSettings()) { error in
                        if let error = error {
                            self.logger.error("[PacketTunnelProvider]failed to set tunnel network settings: \(error.localizedDescription)")
                            return
                        }
                        self.reasserting = false
                        readToDevice(packetFlow: self.packetFlow, device: device)
                    }
    //                self.reasserting = false
                }
            }
        }
        updateWindowStatus(device.getWindowStatus())
        let windowStatusChangeSub = device.add(WindowStatusChangeListener { windowStatus in
            DispatchQueue.main.async {
                updateWindowStatus(windowStatus)
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
        
        let close = {
            packetReceiverSub?.close()
            pathMonitor.cancel()
            routeLocalChangeSub?.close()
            provideChangeSub?.close()
            locationChangeSub?.close()
            windowStatusChangeSub?.close()
            provideNetworkModeChangeSub?.close()
            device.close()
        }
        
//        Thread.setThreadPriority(1.0)
        self.setTunnelNetworkSettings(self.networkSettings()) { _ in
            readToDevice(packetFlow: self.packetFlow, device: device)
        }
        completionHandler(nil)
    }
    
    func networkSettings() -> NEPacketTunnelNetworkSettings {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        
        // IPv4 Configuration
        let ipv4Settings = NEIPv4Settings(addresses: ["169.254.2.1"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        networkSettings.ipv4Settings = ipv4Settings
        
        let ipv6Settings = NEIPv6Settings()
        networkSettings.ipv6Settings = ipv6Settings
        
        // DNS Settings
    //        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        // use settings from connect/net_http_doh
        let dnsSettings = NEDNSOverHTTPSSettings(servers: ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        dnsSettings.serverURL = URL(string: "https://1.1.1.1/dns-query")
        networkSettings.dnsSettings = dnsSettings
        
        // default URnetwork MTU
        networkSettings.mtu = 1440
        
        return networkSettings
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("[PacketTunnelProvider]stop with reason: \(String(describing: reason))")
        
        self.device?.cancel()
        self.memoryPressureSource?.cancel()
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let handler = completionHandler {
            handler(messageData)
        }
    }
}


func readToDevice(packetFlow: NEPacketTunnelFlow, device: SdkDeviceLocal) {
    if device.getDone() {
        return
    }
    // see https://developer.apple.com/documentation/networkextension/nepackettunnelflow/readpackets(completionhandler:)
    // "Each call to this method results in a single execution of the completion handler"
    packetFlow.readPackets { packets, protocols in
//        if (packets.count == 0) {
//            // EOF
//            return
//        }
        
        for packet in packets {
            device.sendPacket(packet, n: Int32(packet.count))
        }
        // note since `readPackets` is async this is not recursion on the call stack
        readToDevice(packetFlow: packetFlow, device: device)
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

private class RouteLocalChangeListener: NSObject, SdkRouteLocalChangeListenerProtocol {
    
    private let c: (_ routeLocal: Bool) -> Void

    init(c: @escaping (_ routeLocal: Bool) -> Void) {
        self.c = c
    }
    
    func routeLocalChanged(_ routeLocal: Bool) {
        c(routeLocal)
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
