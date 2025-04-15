//
//  ConnectViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk
import SwiftUI
import Combine

private class GridListener: NSObject, SdkGridListenerProtocol {
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    
    func gridChanged() {
        callback()
    }
}

private class ConnectionStatusListener: NSObject, SdkConnectionStatusListenerProtocol {

    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    
    func connectionStatusChanged() {
        callback()
    }
    
}

private class SelectedLocationListener: NSObject, SdkSelectedLocationListenerProtocol {
    
    private let callback: (_ location: SdkConnectLocation?) -> Void

    init(callback: @escaping (SdkConnectLocation?) -> Void) {
        self.callback = callback
    }
    
    func selectedLocationChanged(_ location: SdkConnectLocation?) {
        callback(location)
    }
}

enum ConnectionStatus: String {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case destinationSet = "DESTINATION_SET"
    case connected = "CONNECTED"
}


@MainActor
class ConnectViewModel: ObservableObject {
    
    /**
     * Connection status
     */
    @Published private(set) var connectionStatus: ConnectionStatus?
    
    /**
     * Connect grid
     */
    @Published private(set) var windowCurrentSize: Int32 = 0
    @Published private(set) var gridPoints: [SdkId: SdkProviderGridPoint] = [:]
    @Published private(set) var gridWidth: Int32 = 0
    
    /**
     * Selected Provider
     */
    @Published private(set) var selectedProvider: SdkConnectLocation?
    
    /**
     * Prompt ratings
     */
    var requestReview: (() -> Void)?
    
    /**
     * Upgrade guest account sheet
     */
    @Published var isPresentedCreateAccount: Bool = false
    
    /**
     * Tunnel connected
     */
    @Published var tunnelConnected: Bool = false
    
    /**
     * Contract status
     */
    @Published private(set) var contractStatus: SdkContractStatus? = nil
    
    /**
     * Upgrade prompts
     */
    @Published var showUpgradeBanner = false
    @Published var isPresentedUpgradeSheet: Bool = false
    
    private var api: SdkApi?
    var device: SdkDeviceRemote?
    var connectViewController: SdkConnectViewController?
    
    func setup(api: SdkApi?, device: SdkDeviceRemote, connectViewController: SdkConnectViewController?) {
        self.api = api
        self.connectViewController = connectViewController
        
        self.addGridListener()
        self.addConnectionStatusListener()
        self.addSelectedLocationListener()
        
        self.updateConnectionStatus()
        
        self.device = device
        self.selectedProvider = device.getConnectLocation()
        
        /**
         * Add tunnel listener
         */
        self.device?.add(TunnelChangeListener { [weak self] tunnelStarted in
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                self.tunnelConnected = tunnelStarted
            }
        })
        
        /**
         * Add contract status listener for insufficient balance updates
         */
        device.add(ContractStatusChangeListener { [weak self] _ in
            
            guard let self = self else {
                return
            }
            
            self.updateContractStatus()
        })
        
    }
    
    /**
     * Used in the provider list
     */
    func connect(_ provider: SdkConnectLocation) {
        connectViewController?.connect(provider)
        try? device?.getNetworkSpace()?.getAsyncLocalState()?.getLocalState()?.setConnectLocation(provider)
    }
    
    /**
     * Used for the main  connect button
     */
    func connect() {
        if let selectedProvider = self.selectedProvider {
            connectViewController?.connect(selectedProvider)
        } else {
            connectViewController?.connectBestAvailable()
        }
    }
    
    func connectBestAvailable() {
        connectViewController?.connectBestAvailable()
    }
    
    func disconnect() {
        connectViewController?.disconnect()
    }
    
    private func addSelectedLocationListener() {
        let listener = SelectedLocationListener { [weak self] selectedLocation in
            
            guard let self = self else {
                print("SelectedLocationListener no self found")
                return
            }
        
            DispatchQueue.main.async {
                print("new selected location is: \(selectedLocation?.name ?? "none")")
                self.selectedProvider = selectedLocation
            }
        }
        connectViewController?.add(listener)
    }
    
    func getProviderColor(_ provider: SdkConnectLocation) -> Color {
        return Color(hex: SdkGetColorHex(
            provider.locationType == SdkLocationTypeCountry ? provider.countryCode : provider.connectLocationId?.string()
        ))
    }
    
}

// MARK: Contract status
extension ConnectViewModel {
    func updateContractStatus() {
        
        guard let device = self.device else {
            return
        }
        
        if let contractStatus = device.getContractStatus() {
            print("[DeviceManager][contract]insufficent=\(contractStatus.insufficientBalance) nopermission=\(contractStatus.noPermission) premium=\(contractStatus.premium)")
        } else {
            print("[DeviceManager][contract]no contract status")
        }
        
        DispatchQueue.main.async {
            self.contractStatus = device.getContractStatus()
            
            if (self.contractStatus?.insufficientBalance == true && self.connectionStatus != .disconnected) {
                self.disconnect()
            }
            
        }
    }
}

// MARK: grid
extension ConnectViewModel {
    
    private func addGridListener() {
        let listener = GridListener { [weak self] in
            
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                self.updateGrid()
                
            }
            
        }
        connectViewController?.add(listener)
        updateGrid()
    }
    
    private func updateGrid() {
           
       if let grid = self.connectViewController?.getGrid() {
           self.gridWidth = grid.getWidth()
           self.windowCurrentSize = grid.getWindowCurrentSize()
           
           let gridPointList = grid.getProviderGridPointList()
           
           guard let gridPointList = gridPointList else {
               print("grid point list is nil")
               return
           }
           
           var gridPoints: [SdkId: SdkProviderGridPoint] = [:]
           
           for i in 0..<gridPointList.len() {
               
               let gridPoint = gridPointList.get(i)
               
               if let gridPoint = gridPoint, let clientId = gridPoint.clientId {
                   gridPoints[clientId] = gridPoint
                   
                   let state = gridPoint.state
                   print("grid point \(clientId.idStr) state is \(state)")
               }
               
           }
           
           self.gridPoints = gridPoints
           
       } else {
           self.windowCurrentSize = 0
           self.gridPoints = [:]
           self.gridWidth = 0
       }
        
    }
    
}

// MARK: connection status
extension ConnectViewModel {
    
    private func addConnectionStatusListener() {
        let listener = ConnectionStatusListener { [weak self] in
            print("connection status listener hit")
            
            guard let self = self else {
                return
            }
                
            DispatchQueue.main.async {
                self.updateConnectionStatus()
            }
            
        }
        connectViewController?.add(listener)
    }
    
    private func updateConnectionStatus() {
        guard let statusString = self.connectViewController?.getConnectionStatus() else {
            print("no status present")
            return
        }
        
        if let status = ConnectionStatus(rawValue: statusString) {
            self.connectionStatus = status
            
            if status == .connected {
                if let requestReview = self.requestReview {
                    requestReview()
                }
            }
        }
    }
    
}
