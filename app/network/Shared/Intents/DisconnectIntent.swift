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
        
        if !device.getConnected() {
            print("RPC device is not connected")
            return .result(
                dialog: "Error connecting to URnetwork"
            )
        }
        
        guard let connectViewController = device.openConnectViewController() else {
            return .result(dialog: "Failed to connect URnetwork")
        }
        
        let status = connectViewController.getConnectionStatus()
        print("connect status is: \(status)")
        
        if (status == SdkDisconnected) {
            return .result(
                dialog: "URnetwork is disconnected"
            )
        }
        
        try await waitForConnectionStatusDisconnected(connectViewController)
        
        device.close(connectViewController)
        
        try await waitForRemoteClose(
            device: device
        )
        
        return .result(
            dialog: "URnetwork VPN disconnected"
        )
         
    }
    
    enum WaitForDisconnectedError: Error {
        case noStatus
    }
    
    func waitForConnectionStatusDisconnected(
        _ connectViewController: SdkConnectViewController
    ) async throws {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let listener = ConnectionStatusListener {
                
                let statusString = connectViewController.getConnectionStatus()
                
                if let status = ConnectionStatus(rawValue: statusString) {
                    
                    if status == .disconnected {
                        continuation.resume(returning: ())
                    }
                    
                } else {
                    continuation.resume(throwing: WaitForDisconnectedError.noStatus)
                }
                
            }
            
            connectViewController.add(listener)
            
            connectViewController.disconnect()
            
        }
        
    }
    
    func waitForRemoteClose(
        device: SdkDeviceRemote
    ) async throws -> Void {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let listener = RemoteChangeListener { connected in
                
                if (!connected) {
                    continuation.resume(returning: ())
                }
                
            }

            device.add(listener)
            
            device.close()
            
        }
        
    }
    
}

private class RemoteChangeListener: NSObject, SdkRemoteChangeListenerProtocol {
    
    var c: (Bool) -> Void

    init(c: @escaping (Bool) -> Void) {
        self.c = c
    }
    
    func remoteChanged(_ remoteConnected: Bool) {
        c(remoteConnected)
    }
    
}
