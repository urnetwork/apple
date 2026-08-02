//
//  ConnectIntent.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/16.
//

import Foundation
import AppIntents
import URnetworkSdk

struct ConnectIntent: AppIntent {
    
    static let title: LocalizedStringResource = "Connect URnetwork VPN"
    
    static var isSiriAvailable: Bool = true
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    
    // @Parameter(title: location)
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        
        let deviceManager = await DeviceManager()
        
        await deviceManager.waitForDeviceInitialization()
        
        guard let device = await deviceManager.device else {
            return .result(
                dialog: "Please login to URnetwork to connect"
            )
        }
        
        guard let connectViewController = device.openConnectViewController() else {
            return .result(dialog: "Failed to connect")
        }
        defer {
            device.close(connectViewController)
        }
        
        var status = connectViewController.getConnectionStatus()
        if (status != SdkDisconnected) {
            return .result(dialog: "URnetwork VPN already started")
        }
        
        
        if let location = device.getConnectLocation() {
            connectViewController.connect(location)
        } else {
            connectViewController.connectBestAvailable()
        }

        guard let vpnManager = await deviceManager.vpnManager else {
            return .result(dialog: "Failed to start URnetwork VPN")
        }

        let vpnUpdateResult = await vpnManager.updateVpnServiceAndWait()
        if case .failure(let error) = vpnUpdateResult {
            print("[ConnectIntent] failed to update VPN service: \(error.localizedDescription)")
            return .result(dialog: "Failed to start URnetwork VPN")
        }
        
        status = connectViewController.getConnectionStatus()
        print("post connect status is: \(status)")
        
        return .result(dialog: "URnetwork VPN started")
             
    }
    
}
