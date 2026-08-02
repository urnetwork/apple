//
//  DisconnectIntent.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/17.
//

import Foundation
import AppIntents
import URnetworkSdk

struct DisconnectIntent: AppIntent {
    
    static let title: LocalizedStringResource = "Disconnect URnetwork VPN"
    
    static var isSiriAvailable: Bool = true
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        
        let deviceManager = await DeviceManager()
        
        await deviceManager.waitForDeviceInitialization()
        
        guard let device = await deviceManager.device else {
            return .result(
                dialog: "Please login to URnetwork"
            )
        }

        guard let vpnManager = await deviceManager.vpnManager else {
            return .result(dialog: "Failed to disconnect URnetwork VPN")
        }
        
        if !device.getConnected() {
            print("RPC device is not connected")
            if let error = await vpnManager.stopVpnTunnelOnQuitAndWait() {
                print("[DisconnectIntent] failed to remove stale VPN profiles: \(error.localizedDescription)")
                return .result(dialog: "Failed to disconnect URnetwork VPN")
            }
            return .result(dialog: "URnetwork VPN disconnected")
        }
        
        guard let connectViewController = device.openConnectViewController() else {
            return .result(dialog: "Failed to connect URnetwork")
        }
        defer {
            device.close(connectViewController)
        }
        
        var status = connectViewController.getConnectionStatus()
        print("connect status is: \(status)")
        
        if status != SdkDisconnected {
            connectViewController.disconnect()
        }

        let vpnUpdateResult = await vpnManager.updateVpnServiceAndWait()
        if case .failure(let error) = vpnUpdateResult {
            print("[DisconnectIntent] failed to update VPN service: \(error.localizedDescription)")
            return .result(dialog: "Failed to disconnect URnetwork VPN")
        }
        
        status = connectViewController.getConnectionStatus()
        print("after disconnect status is: \(status)")
        
        if status == SdkDisconnected {
            return .result(dialog: "URnetwork is disconnected")
        }

        return .result(dialog: "URnetwork VPN disconnected")
         
    }
    
}
