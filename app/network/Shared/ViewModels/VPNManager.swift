//
//  VPNManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/20.
//

import Foundation
import NetworkExtension
import URnetworkSdk

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

@MainActor
class VPNManager {
    
    var device: SdkDeviceRemote
    
//    var tunnelRequestStatus: TunnelRequestStatus = .none
    
    private var routeLocalSub: SdkSubProtocol?
    
    private var deviceProvideSub: SdkSubProtocol?
    
    private var deviceProvidePausedSub: SdkSubProtocol?
    
    private var deviceOfflineSub: SdkSubProtocol?
    
    private var deviceConnectSub: SdkSubProtocol?
    
//    var deviceRemoteSub: SdkSubProtocol?
    
    private var tunnelSub: SdkSubProtocol?
    
    var contractStatusSub: SdkSubProtocol?
    
    
    init(device: SdkDeviceRemote) {
        print("[VPNManager]init")
        self.device = device
        
        self.routeLocalSub = device.add(RouteLocalChangeListener { [weak self] routeLocal in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.deviceProvideSub = device.add(ProvideChangeListener { [weak self] provideEnabled in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.deviceProvidePausedSub = device.add(ProvidePausedChangeListener { [weak self] providePaused in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.deviceOfflineSub = device.add(OfflineChangeListener { [weak self] offline, vpnInterfaceWhileOffline in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.deviceConnectSub = device.add(ConnectChangeListener { [weak self] connectEnabled in
            DispatchQueue.main.async {
                self?.updateVpnService()
            }
        })
        
        self.tunnelSub = device.add(TunnelChangeListener { [weak self] tunnelStarted in
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                self.updateTunnel()
                
                // note this makes it impossible to turn off the vpn from settings
                // until it's possible to tell whether the tunnel ended from user preference or crash,
                // we won't be able to support the settings without compromising reliability of the tunnel
                if !tunnelStarted {
                    // the tunnel stopped unexpectedly. Sync with state.
//                    self.tunnelRequestStatus = .none
                    self.updateVpnService()
                }
            }
        })
        
        self.contractStatusSub = device.add(ContractStatusChangeListener { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateContractStatus()
            }
        })
        
        updateTunnel()
        updateContractStatus()
        
        updateVpnService()
    }
    
//    deinit {
//        print("VPN Manager deinit")
//        
//        self.close()
//    }
    
    func close() async {
        await self.stopVpnTunnel()
        
        // UIApplication.shared.isIdleTimerDisabled = false
        self.setIdleTimerDisabled(false)
        
        self.routeLocalSub?.close()
        self.routeLocalSub = nil
        
        self.deviceProvideSub?.close()
        self.deviceProvideSub = nil
        
        self.deviceProvidePausedSub?.close()
        self.deviceProvidePausedSub = nil
        
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
    }
    
    
    private func getPasswordReference() -> Data? {
        // Retrieve the password reference from the keychain
        return nil
    }
    
    
    private func updateTunnel() {
        let tunnelStarted = self.device.getTunnelStarted()
        print("[VPNManager][tunnel]started=\(tunnelStarted)")
    }
    
    private func updateContractStatus() {
        if let contractStatus = self.device.getContractStatus() {
            print("[VPNManager][contract]insufficent=\(contractStatus.insufficientBalance) nopermission=\(contractStatus.noPermission) premium=\(contractStatus.premium)")
        } else {
            print("[VPNManager][contract]no contract status")
        }
    }
    
    
    func updateVpnService() {
        let provideEnabled = device.getProvideEnabled()
        let providePaused = device.getProvidePaused()
        let connectEnabled = device.getConnectEnabled()
        let routeLocal = device.getRouteLocal()
        
        if (provideEnabled || connectEnabled || !routeLocal) {
            print("[VPNManager]start")
            
            // see https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
//            if providePaused {
//                UIApplication.shared.isIdleTimerDisabled = false
//            } else {
//                UIApplication.shared.isIdleTimerDisabled = true
//            }
            
            setIdleTimerDisabled(providePaused ? false : true)
            
            self.startVpnTunnel()
            
            
        } else {
            print("[VPNManager]stop")
            

            self.setIdleTimerDisabled(false)
            
            Task {
                await self.stopVpnTunnel()
            }
            
        }
    }
    
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #elseif canImport(AppKit)
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = !disabled
        #endif
    }
    
    
    private func startVpnTunnel() {
//        if self.tunnelRequestStatus == .started {
//            return
//        }
//        self.tunnelRequestStatus = .started
        
        // Load all configurations first
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if let error = error {
                print("Error loading managers: \(error.localizedDescription)")
//                self.tunnelRequestStatus = .none
                return
            }
//            if self.tunnelRequestStatus != .started {
//                return
//            }
//            guard let self = self else {
//                return
//            }
            
            // Use existing manager or create new one
            let tunnelManager = managers?.first ?? NETunnelProviderManager()

            
            guard let networkSpace = self.device.getNetworkSpace() else {
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
                "by_jwt": self.device.getApi()?.getByJwt() as Any,
                "rpc_public_key": "test",
                "network_space": networkSpaceJson as Any,
                "instance_id": self.device.getInstanceId()?.string() as Any,
            ]
            
            
            tunnelManager.protocolConfiguration = tunnelProtocol
            tunnelManager.localizedDescription = "URnetwork [\(networkSpace.getHostName()) \(networkSpace.getEnvName())]"
            tunnelManager.isEnabled = true
            tunnelManager.isOnDemandEnabled = true
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = NEOnDemandRuleInterfaceType.any
            tunnelManager.onDemandRules = [connectRule]
            
            tunnelManager.saveToPreferences { error in
                if let _ = error {
                    // when changing locations quickly, another change might have intercepted this save
//                    self.tunnelRequestStatus = .none
                    return
                }
//                if self.tunnelRequestStatus != .started {
//                    return
//                }
                
                // see https://forums.developer.apple.com/forums/thread/25928
                tunnelManager.loadFromPreferences { error in
                    if let _ = error {
//                        self.tunnelRequestStatus = .none
                        return
                    }
//                    if self.tunnelRequestStatus != .started {
//                        return
//                    }
                    

                    do {
                        try tunnelManager.connection.startVPNTunnel()
                        print("[VPNManager]connection started")
                        self.device.sync()
                    } catch let error as NSError {
//                        self.tunnelRequestStatus = .none
                        print("[VPNManager]Error starting VPN connection:")
                        print("[VPNManager]Domain: \(error.domain)")
                        print("[VPNManager]Code: \(error.code)")
                        print("[VPNManager]Description: \(error.localizedDescription)")
                        print("[VPNManager]User Info: \(error.userInfo)")
                        
                    }
                }
            }
        }
    }
    
    private func stopVpnTunnel() async {
        return await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
                if let error = error {
                    print("[VPNManager]error loading managers: \(error.localizedDescription)")
                    continuation.resume()
                    return
                }
                
                guard let tunnelManager = managers?.first else {
                    continuation.resume()
                    return
                }
                
                tunnelManager.isEnabled = false
                tunnelManager.isOnDemandEnabled = false
                
                tunnelManager.saveToPreferences { error in
                    if let error = error {
                        print("[VPNManager]error saving preferences: \(error.localizedDescription)")
                        continuation.resume()
                        return
                    }
                    
                    tunnelManager.loadFromPreferences { error in
                        if let error = error {
                            print("[VPNManager]error loading preferences: \(error.localizedDescription)")
                            continuation.resume()
                            return
                        }
                        
                        tunnelManager.connection.stopVPNTunnel()
                        
                        // Give a short delay to ensure the tunnel is fully stopped
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            continuation.resume()
                        }
                    }
                }
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

private class ContractStatusChangeListener: NSObject, SdkContractStatusChangeListenerProtocol {
    
    private let c: (_ contractStatus: SdkContractStatus?) -> Void

    init(c: @escaping (_ contractStatus: SdkContractStatus?) -> Void) {
        self.c = c
    }
    
    func contractStatusChanged(_ contractStatus: SdkContractStatus?) {
        c(contractStatus)
    }
}

