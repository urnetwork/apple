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

        // a start: out of balance it is refused and the app opens, where the
        // connect view offers the upgrade (see InsufficientBalancePolicy)
        let api = await deviceManager.api
        let decision = await resolveStartConnect(
            .start,
            guards: StartConnectGuards(
                contractInsufficientBalance: device.getContractStatus()?.insufficientBalance == true
            ),
            cachedBalance: WidgetSnapshotStore.loadBalance(),
            now: Date(),
            fetchBalance: { await StartConnectBalanceFetch.fetch(api: api) }
        )
        if decision == .upgrade {
            if #available(iOS 18.2, macOS 15.2, *) {
                return .result(opensIntent: OpenURnetworkIntent(), dialog: "Insufficient balance")
            }
            return .result(dialog: "Insufficient balance")
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
