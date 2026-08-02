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
    private let lock = NSLock()
    private var scheduled = false
    private var dirty = false
    private let callback: @MainActor () -> Void

    init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    func gridChanged() {
        lock.lock()
        if scheduled {
            dirty = true
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        callback()

        lock.lock()
        if dirty {
            dirty = false
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.drain()
            }
        } else {
            scheduled = false
            lock.unlock()
        }
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

private class ConnectLocationStateListener: NSObject, SdkConnectLocationChangeListenerProtocol {
    private let callback: (_ location: SdkConnectLocation?) -> Void

    init(callback: @escaping (_ location: SdkConnectLocation?) -> Void) {
        self.callback = callback
    }

    func connectLocationChanged(_ location: SdkConnectLocation?) {
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
    @Published var isPresentedUpgradeSheet: Bool = false
    
    private var api: SdkApi?
    var device: SdkDeviceRemote?
    var connectViewController: SdkConnectViewController?
    
    private var gridListenerSub: SdkSubProtocol?
    private var connectionStatusListenerSub: SdkSubProtocol?
    private var selectedLocationListenerSub: SdkSubProtocol?
    private var tunnelListenerSub: SdkSubProtocol?
    private var contractListenerSub: SdkSubProtocol?
    private var connectLocationStateSub: SdkSubProtocol?

    // last published grid signature; skip redundant re-renders when the SDK
    // re-emits a logically unchanged grid (its point objects get fresh
    // identities each notification, which would otherwise storm @Published)
    private var lastGridSignature: String = ""

    func setup(api: SdkApi?, device: SdkDeviceRemote, connectViewController: SdkConnectViewController?) {
        closeListeners()
        closeConnectViewController()

        self.api = api
        self.device = device
        self.connectViewController = connectViewController

        self.addGridListener()
        self.addConnectionStatusListener()
        self.addSelectedLocationListener()

        self.updateConnectionStatus()

        // if a user was connected and quit the app, it will reconnect this location
        self.selectedProvider = device.getConnectLocation()

        // if a user had selected a location, but wasn't connected, it will re-select that location
        if (self.selectedProvider == nil) {
            self.selectedProvider = device.getDefaultLocation()
        }

        /**
         * Add tunnel listener
         */
        self.tunnelListenerSub = self.device?.add(TunnelChangeListener { [weak self] tunnelStarted in
            guard let self = self else {
                return
            }

            DispatchQueue.main.async {
                self.tunnelConnected = tunnelStarted
            }
        })

        self.refreshTunnelStatus()

        self.contractListenerSub = device.add(ContractStatusChangeListener { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.updateContractStatus()
            }
        })
    }

    /**
     * Release all presentation-only SDK work while retaining the last device and
     * published snapshot. The packet tunnel/provider owns data-plane continuity;
     * reopening the scene calls `setup` and obtains a fresh controller snapshot.
     */
    func suspend(api: SdkApi?, device: SdkDeviceRemote?) {
        closeListeners()
        closeConnectViewController()
        self.api = api
        self.device = device
        addBackgroundConnectionStateListener()
    }

    func reset() {
        closeListeners()
        closeConnectViewController()

        self.api = nil
        self.device = nil

        self.connectionStatus = nil
        self.windowCurrentSize = 0
        self.gridPoints = [:]
        self.gridWidth = 0
        self.lastGridSignature = ""
        self.selectedProvider = nil
        self.tunnelConnected = false
        self.contractStatus = nil
        self.isPresentedCreateAccount = false
        self.isPresentedUpgradeSheet = false
    }

    private func closeListeners() {
        gridListenerSub?.close()
        connectionStatusListenerSub?.close()
        selectedLocationListenerSub?.close()
        tunnelListenerSub?.close()
        contractListenerSub?.close()
        connectLocationStateSub?.close()

        gridListenerSub = nil
        connectionStatusListenerSub = nil
        selectedLocationListenerSub = nil
        tunnelListenerSub = nil
        contractListenerSub = nil
        connectLocationStateSub = nil
    }

    private func closeConnectViewController() {
        if let connectViewController {
            if let device {
                device.close(connectViewController)
            } else {
                connectViewController.close()
            }
        }
        connectViewController = nil
    }

    /**
     * The macOS tray stays interactive while its window is hidden. Keep only
     * the device's event-driven location state so tray connect/disconnect
     * commands update their label; all polling and presentation controllers
     * remain closed. On iOS this listener is inert while the app is suspended.
     */
    private func addBackgroundConnectionStateListener() {
        guard let device else {
            return
        }

        updateBackgroundConnectionState(device.getConnectLocation())
        connectLocationStateSub = device.add(ConnectLocationStateListener { [weak self] location in
            DispatchQueue.main.async {
                self?.updateBackgroundConnectionState(location)
            }
        })
    }

    private func updateBackgroundConnectionState(_ location: SdkConnectLocation?) {
        selectedProvider = location ?? selectedProvider
        connectionStatus = location == nil ? .disconnected : .destinationSet
    }
    
    func refreshTunnelStatus() {
        self.tunnelConnected = self.device?.getTunnelStarted() ?? false
    }
    
    /**
     * Used in the provider list
     */
    func connect(_ provider: SdkConnectLocation) {
        withCommandViewController { viewController in
            viewController.connect(provider)
        }
        try? device?.getNetworkSpace()?.getAsyncLocalState()?.getLocalState()?.setConnectLocation(provider)
    }
    
    /**
     * Used for the main  connect button
     */
    func connect() {
        if let selectedProvider = self.selectedProvider {
            withCommandViewController { viewController in
                viewController.connect(selectedProvider)
            }
        } else {
            connectBestAvailable()
        }
    }
    
    func connectBestAvailable() {
        withCommandViewController { viewController in
            viewController.connectBestAvailable()
        }
    }
    
    func disconnect() {
        withCommandViewController { viewController in
            viewController.disconnect()
        }
    }

    private func withCommandViewController(_ command: (SdkConnectViewController) -> Void) {
        if let connectViewController {
            command(connectViewController)
            return
        }
        guard let device, let viewController = device.openConnectViewController() else {
            return
        }
        defer {
            device.close(viewController)
        }
        command(viewController)
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
        selectedLocationListenerSub = connectViewController?.add(listener)
    }
    
//    func getProviderColor(_ provider: SdkConnectLocation) -> Color {
//        return Color(hex: SdkGetColorHex(
//            provider.locationType == SdkLocationTypeCountry ? provider.countryCode : provider.connectLocationId?.string()
//        ))
//    }
    
}

// MARK: Contract status
extension ConnectViewModel {
    func updateContractStatus() {

        guard let device = self.device else {
            return
        }

        let status = device.getContractStatus()
        // only publish when a field the UI reads actually changed; the SDK
        // re-emits a fresh SdkContractStatus (new identity) each callback, which
        // would otherwise re-render the whole connect screen on every tick
        if !Self.contractStatusEqual(status, self.contractStatus) {
            self.contractStatus = status
        }

        if status?.insufficientBalance == true && self.connectionStatus != .disconnected {
            self.disconnect()
        }
    }

    private static func contractStatusEqual(_ a: SdkContractStatus?, _ b: SdkContractStatus?) -> Bool {
        if a == nil, b == nil { return true }
        guard let a = a, let b = b else { return false }
        return a.insufficientBalance == b.insufficientBalance
            && a.noPermission == b.noPermission
            && a.premium == b.premium
    }
}

// MARK: grid
extension ConnectViewModel {
    
    private func addGridListener() {
        let listener = GridListener { [weak self] in
            self?.updateGrid()
        }
        gridListenerSub = connectViewController?.add(listener)
        updateGrid()
    }
    
    private func gridSignature() -> String {
        guard let grid = self.connectViewController?.getGrid() else { return "" }
        var sig: [String] = []
        if let list = grid.getProviderGridPointList() {
            for i in 0..<list.len() {
                if let p = list.get(i), let cid = p.clientId {
                    sig.append("\(cid.idStr):\(p.state):\(p.x):\(p.y)")
                }
            }
        }
        sig.sort()
        return "\(grid.getWidth())x\(grid.getWindowCurrentSize());" + sig.joined(separator: "|")
    }

    func updateGrid() {

        // skip the @Published publish (and the downstream re-render + grid
        // animation) when the grid is logically unchanged. the SDK re-emits
        // grid notifications with fresh point objects, so assigning gridPoints
        // unconditionally would storm observers on every notification even when
        // nothing actually moved — a real cost during connect/reconnect churn.
        let signature = gridSignature()
        if signature == lastGridSignature {
            return
        }
        lastGridSignature = signature

       if let grid = self.connectViewController?.getGrid() {
           self.gridWidth = grid.getWidth()
           self.windowCurrentSize = grid.getWindowCurrentSize()
           
           let gridPointList = grid.getProviderGridPointList()
           
           guard let gridPointList = gridPointList else {
               return
           }
           
           var gridPoints: [SdkId: SdkProviderGridPoint] = [:]
           
           for i in 0..<gridPointList.len() {
               
               let gridPoint = gridPointList.get(i)
               
               if let gridPoint = gridPoint, let clientId = gridPoint.clientId {
                   gridPoints[clientId] = gridPoint
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
            guard let self = self else {
                return
            }
                
            DispatchQueue.main.async {
                self.updateConnectionStatus()
            }
            
        }
        connectionStatusListenerSub = connectViewController?.add(listener)
    }

    private func updateConnectionStatus() {
        guard let statusString = self.connectViewController?.getConnectionStatus() else {
            print("no status present")
            return
        }
        
        if let status = ConnectionStatus(rawValue: statusString) {
            guard status != self.connectionStatus else {
                return
            }
            self.connectionStatus = status
            
            if status == .connected {
                if let requestReview = self.requestReview {
                    requestReview()
                }
            }
        }
    }
    
}
