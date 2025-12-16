//
//  VPNManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/20.
//

import Foundation
import NetworkExtension
import URnetworkSdk
import Network
import BackgroundTasks

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

//enum TunnelRequestStatus {
//    case started
//    case stopped
//    case none
//}

let TunnelCheckTimeout: TimeInterval = 5

@MainActor
class VPNManager {
    
    var device: SdkDeviceRemote
    
//    var tunnelRequestStatus: TunnelRequestStatus = .none
    
    private var routeLocalSub: SdkSubProtocol?
    
    private var deviceOfflineSub: SdkSubProtocol?
    
    private var deviceConnectSub: SdkSubProtocol?
    
//    var deviceRemoteSub: SdkSubProtocol?
    
    private var tunnelSub: SdkSubProtocol?
    
    private var deviceProvideSub: SdkSubProtocol?
    private var deviceProvidePausedSub: SdkSubProtocol?
    
    private var tunnelStarted: Bool = false
    private var tunnelInstance: Int = 0
    
    var contractStatusSub: SdkSubProtocol?
    
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "NetworkMonitor")
    
    
    init(device: SdkDeviceRemote) {
        print("[VPNManager]init")
        self.device = device
        
        #if os(iOS)
//        BGTaskScheduler.shared.register(forTaskWithIdentifier: "ur.network.update-tunnel", using: nil) { task in
//             self.handleBackgroundUpdate(task: task as! BGAppRefreshTask)
//        }
        #endif
        
        self.monitor.start(queue: queue)
        
        self.routeLocalSub = device.add(RouteLocalChangeListener { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
             
        self.deviceOfflineSub = device.add(OfflineChangeListener { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.deviceConnectSub = device.add(ConnectChangeListener { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
//        self.tunnelSub = device.add(TunnelChangeListener { [weak self] _ in
//            DispatchQueue.main.async {
//                self?.updateTunnel()
//            }
//        })
        
//        self.contractStatusSub = device.add(ContractStatusChangeListener { [weak self] _ in
//            DispatchQueue.main.async {
//                self?.updateContractStatus()
//            }
//        })
        
        self.deviceProvidePausedSub = device.add(ProvidePausedChangeListener { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.deviceProvideSub = device.add(ProvideChangeListener { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
//        updateTunnel()
//        updateContractStatus()
        
        updateVpnService()
    }
    
    #if os(iOS)
    func scheduleBackgroundUpdate() {
//       let request = BGAppRefreshTaskRequest(identifier: "ur.network.update-tunnel")
//       request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
//
//       do {
//          try BGTaskScheduler.shared.submit(request)
//       } catch {
//          print("Could not schedule background update: \(error)")
//       }
    }
    
    func handleBackgroundUpdate(task: BGAppRefreshTask) {
//        self.updateVpnService()
    }
    #endif
    
    
    
//    deinit {
//        print("VPN Manager deinit")
//        
//        self.close()
//    }
    
    func close() {
//        self.stopVpnTunnel(index: 0, reset: true)
        
        // UIApplication.shared.isIdleTimerDisabled = false
        self.setIdleTimerDisabled(false)
        
        self.routeLocalSub?.close()
        self.routeLocalSub = nil
        
        self.deviceOfflineSub?.close()
        self.deviceOfflineSub = nil
        
        self.deviceConnectSub?.close()
        self.deviceConnectSub = nil
        
//        self.deviceRemoteSub?.close()
//        self.deviceRemoteSub = nil
        
        self.tunnelSub?.close()
        self.tunnelSub = nil
        
        self.contractStatusSub?.close()
        self.contractStatusSub = nil
        
        self.deviceProvideSub?.close()
        self.deviceProvideSub = nil
        
        self.deviceProvidePausedSub?.close()
        self.deviceProvidePausedSub = nil
    }
    
    
    private func getPasswordReference() -> Data? {
        // Retrieve the password reference from the keychain
        return nil
    }
    
    
//    private func updateTunnel() {
//        let tunnelStarted = self.device.getTunnelStarted()
//        print("[VPNManager][tunnel]started=\(tunnelStarted)")
//    }
    
//    private func updateContractStatus() {
//        if let contractStatus = self.device.getContractStatus() {
//            print("[VPNManager][contract]insufficent=\(contractStatus.insufficientBalance) nopermission=\(contractStatus.noPermission) premium=\(contractStatus.premium)")
//        } else {
//            print("[VPNManager][contract]no contract status")
//        }
//    }
    
    private func allowProvideOnCurrentNetwork(
        _ provideNetworkMode: ProvideNetworkMode,
    ) -> Bool {
        
        if (!monitor.currentPath.isExpensive) {
            // is not cell or personal hotspot
            // should be able to provide
            print("monitor.currentPath is \(monitor.currentPath.availableInterfaces)")
            return true
        } else {
            
            // only allow providing on cell if provideNetworkMode == .All
            if provideNetworkMode == .All {
                print("monitor.currentPath is expensive and provideNetworkMode == .All")
                return true
            } else {
                print("monitor.currentPath is expensive and provideNetworkMode != .All")
            }
            
        }
        
        return false
    }
    
    
    func updateVpnService() {
        #if os(iOS)
        scheduleBackgroundUpdate()
        #endif
        updateVpnServiceWithReset(index: 0, reset: false)
    }
    
    private func updateVpnServiceWithReset(index: Int, reset: Bool) {
        let provideEnabled = device.getProvideEnabled()
        let connectEnabled = device.getConnectEnabled()
        let routeLocal = device.getRouteLocal()
        let providePaused = device.getProvidePaused()
        
        print("provideEnabled is: \(provideEnabled)")
        print("connect enabled: \(connectEnabled)")
        print("routeLocal is: \(routeLocal)")
        
        if (provideEnabled || connectEnabled || !routeLocal) {
            print("[VPNManager]start")
            
            // if provide paused, keep the vpn on but do not keep the locks
            setIdleTimerDisabled(!providePaused)
            
            self.startVpnTunnel(index: index, reset: reset)
            
        } else {
            print("[VPNManager]stop")

            self.setIdleTimerDisabled(false)
            
            self.stopVpnTunnel(index: index, reset: reset)
        }
    }
    
    private func setIdleTimerDisabled(_ disabled: Bool) {
        // see https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #elseif canImport(AppKit)
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = !disabled
        #endif
    }
    
    
    private func startVpnTunnel(index: Int, reset: Bool) {
        if tunnelStarted {
            return
        }
        tunnelStarted = true
        self.tunnelInstance += 1
        let tunnelInstance = self.tunnelInstance
        
        // Load all configurations first
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if tunnelInstance != self.tunnelInstance {
                return
            }
            
            if let _ = error {
                self.updateVpnService()
                return
            }
            
            let device = self.device
            
            var tunnelManager: NETunnelProviderManager
            var n: Int
            // Use existing manager or create new one
            if let managers = managers {
                n = managers.count
                if index < n {
                    tunnelManager = managers[index]
                } else {
                    tunnelManager = NETunnelProviderManager()
                }
            } else {
                n = 0
                tunnelManager = NETunnelProviderManager()
            }
            
            
            let startTunnel = {
                if tunnelInstance != self.tunnelInstance {
                    return
                }
                
                guard let networkSpace = device.getNetworkSpace() else {
                    return
                }
                
                var err: NSError?
                let networkSpaceJson = networkSpace.toJson(&err)
                if let err {
                    print("[VPNManager]error converting network space to json: \(err.localizedDescription)")
                    return
                }
                
                
                let tunnelProtocol = NETunnelProviderProtocol()
                // Use the same as remote address in PacketTunnelProvider
                // value from connect resolvedHost
                tunnelProtocol.serverAddress = networkSpace.getHostName()
                tunnelProtocol.providerBundleIdentifier = "network.ur.extension"
                tunnelProtocol.disconnectOnSleep = false
                
                // Note `includeAllNetworks` seems to break Facetime and mail sync
                // FIXME figure out the best setting here
                // see https://developer.apple.com/documentation/networkextension/nevpnprotocol/includeallnetworks
    //            tunnelProtocol.includeAllNetworks = true
                
                // this is needed for casting, etc.
                tunnelProtocol.excludeLocalNetworks = true
                tunnelProtocol.excludeCellularServices = true
                tunnelProtocol.excludeAPNs = true
                if #available(iOS 17.4, macOS 14.4, *) {
                    tunnelProtocol.excludeDeviceCommunication = true
                }
                
    //            tunnelProtocol.enforceRoutes = true
                
                tunnelProtocol.providerConfiguration = [
                    "by_jwt": device.getApi()?.getByJwt() as Any,
                    "rpc_public_key": "test",
                    "network_space": networkSpaceJson as Any,
                    "instance_id": device.getInstanceId()?.string() as Any,
                ]
                
                tunnelManager.protocolConfiguration = tunnelProtocol
                tunnelManager.localizedDescription = "URnetwork [\(networkSpace.getHostName()) \(networkSpace.getEnvName())]"
                tunnelManager.isEnabled = true
                tunnelManager.isOnDemandEnabled = true
                let connectRule = NEOnDemandRuleConnect()
                connectRule.interfaceTypeMatch = NEOnDemandRuleInterfaceType.any
                tunnelManager.onDemandRules = [connectRule]
                
                tunnelManager.saveToPreferences { error in
                    if tunnelInstance != self.tunnelInstance {
                        return
                    }
                    
                    if let _ = error {
                        self.updateVpnService()
                        return
                    }
                    
                    // see https://forums.developer.apple.com/forums/thread/25928
                    tunnelManager.loadFromPreferences { error in
                        if tunnelInstance != self.tunnelInstance {
                            return
                        }
                        
                        if let _ = error {
                            self.updateVpnService()
                            return
                        }
                        
                        do {
                            try tunnelManager.connection.startVPNTunnel()
                            print("[VPNManager]connection started")
                            device.sync()
                            
                            if !reset || index+1<n {
                                DispatchQueue.main.asyncAfter(deadline: .now() + TunnelCheckTimeout) {
                                    if tunnelInstance == self.tunnelInstance && !device.getTunnelStarted() {
                                        if !reset {
                                            self.updateVpnServiceWithReset(index: index, reset: true)
                                        } else if index+1<n {
                                            self.updateVpnServiceWithReset(index: index+1, reset: false)
                                        }
                                    }
                                }
                            }
                        } catch let error as NSError {
                            print("[VPNManager]Error starting VPN connection:")
                            print("[VPNManager]Domain: \(error.domain)")
                            print("[VPNManager]Code: \(error.code)")
                            print("[VPNManager]Description: \(error.localizedDescription)")
                            print("[VPNManager]User Info: \(error.userInfo)")
                        }
                    }
                }
                
            }
            
            if reset {
                tunnelManager.removeFromPreferences() { error in
                    if tunnelInstance != self.tunnelInstance {
                        return
                    }
                    
                    if let _ = error {
                        self.updateVpnService()
                        return
                    }
                    
                    startTunnel()
                }
            } else {
                // use a soft relaunch where the settings are updated but the configuration is left in place
                startTunnel()
            }
        }
    }
    
    private func stopVpnTunnel(index: Int, reset: Bool) {
        if !tunnelStarted {
            return
        }
        tunnelStarted = false
        self.tunnelInstance += 1
        let tunnelInstance = self.tunnelInstance
        
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if tunnelInstance != self.tunnelInstance {
                return
            }
            
            if let _ = error {
                self.updateVpnService()
                return
            }
            
            let device = self.device
            
            var tunnelManager: NETunnelProviderManager
            var n: Int
            // Use existing manager or create new one
            if let managers = managers {
                n = managers.count
                if index < n {
                    tunnelManager = managers[index]
                } else {
                    tunnelManager = NETunnelProviderManager()
                }
            } else {
                n = 0
                tunnelManager = NETunnelProviderManager()
            }
            
            tunnelManager.isEnabled = false
            tunnelManager.isOnDemandEnabled = false
            tunnelManager.onDemandRules = nil
            
            tunnelManager.saveToPreferences { error in
                if tunnelInstance != self.tunnelInstance {
                    return
                }
                
                if let _ = error {
                    self.updateVpnService()
                    return
                }
                
                tunnelManager.connection.stopVPNTunnel()
                
                let checkTunnel = {
                    DispatchQueue.main.asyncAfter(deadline: .now() + TunnelCheckTimeout) {
                        if tunnelInstance == self.tunnelInstance && device.getTunnelStarted() {
                            if !reset {
                                self.updateVpnServiceWithReset(index: index, reset: true)
                            } else if index+1<n {
                                self.updateVpnServiceWithReset(index: index+1, reset: false)
                            }
                        }
                    }
                }
                
                if reset {
                    tunnelManager.removeFromPreferences() { error in
                        if tunnelInstance != self.tunnelInstance {
                            return
                        }
                        
                        if let _ = error {
                            self.updateVpnService()
                            return
                        }
                        
                        checkTunnel()
                    }
                } else if index+1<n {
                    checkTunnel()
                }
            }
        }
    }
    
    
    func stopVpnTunnelOnQuit(completion: @escaping (Error?) -> Void) {
        // remove all vpn profiles
        self.stopVpnTunnelOnQuitWithIndex(index: 0, completion: completion)
    }
    
    private func stopVpnTunnelOnQuitWithIndex(index: Int, completion: @escaping (Error?) -> Void) {
        self.tunnelInstance += 1
        
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if let error = error {
                completion(error)
                return
            }
            
            if let managers = managers {
                let n = managers.count
                if index < n {
                    let tunnelManager = managers[index]
                    tunnelManager.removeFromPreferences() { _ in
                        self.stopVpnTunnelOnQuitWithIndex(index: index+1, completion: completion)
                    }
                } else {
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
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

private class OfflineChangeListener: NSObject, SdkOfflineChangeListenerProtocol {
    
    private let c: (_ offline: Bool, _ vpnInterfaceWhileOffline: Bool) -> Void

    init(c: @escaping (_ offline: Bool, _ vpnInterfaceWhileOffline: Bool) -> Void) {
        self.c = c
    }
    
    func offlineChanged(_ offline: Bool, vpnInterfaceWhileOffline: Bool) {
        c(offline, vpnInterfaceWhileOffline)
    }
}

private class ConnectChangeListener: NSObject, SdkConnectChangeListenerProtocol {
    
    private let c: (_ connectEnabled: Bool) -> Void

    init(c: @escaping (_ connectEnabled: Bool) -> Void) {
        self.c = c
    }
    
    func connectChanged(_ connectEnabled: Bool) {
        c(connectEnabled)
    }
}

private class RemoteChangeListener: NSObject, SdkRemoteChangeListenerProtocol {
    
    private let c: (_ remoteConnected: Bool) -> Void

    init(c: @escaping (_ remoteConnected: Bool) -> Void) {
        self.c = c
    }
    
    func remoteChanged(_ remoteConnected: Bool) {
        c(remoteConnected)
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
