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

private class FindLocationsCallback: SdkCallback<SdkFindLocationsResult, SdkFindLocationsCallbackProtocol>, SdkFindLocationsCallbackProtocol {
    func result(_ result: SdkFindLocationsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum FetchProvidersError: Error {
    case noProvidersFound
}

private class GridListener: NSObject, SdkGridListenerProtocol {
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    
    func gridChanged() {
        callback()
    }
}

class ConnectionStatusListener: NSObject, SdkConnectionStatusListenerProtocol {

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
     * Provider groups
     */
    @Published private(set) var providerCountries: [SdkConnectLocation] = []
    @Published private(set) var providerPromoted: [SdkConnectLocation] = []
    @Published private(set) var providerDevices: [SdkConnectLocation] = []
    @Published private(set) var providerRegions: [SdkConnectLocation] = []
    @Published private(set) var providerCities: [SdkConnectLocation] = []
    @Published private(set) var providerBestSearchMatches: [SdkConnectLocation] = []
    
    /**
     * Provider loading state
     */
    @Published private(set) var providersLoading: Bool = false
    
    /**
     * Connection status
     */
    @Published private(set) var connectionStatus: ConnectionStatus?
    
    /**
     * Connect grid
     */
    @Published private(set) var grid: SdkConnectGrid? = nil // might not need this to be tracked...
    @Published private(set) var windowCurrentSize: Int32 = 0
    @Published private(set) var gridPoints: [SdkId: SdkProviderGridPoint] = [:]
    @Published private(set) var gridWidth: Int32 = 0
    
    /**
     * Selected Provider
     */
    @Published private(set) var selectedProvider: SdkConnectLocation?
    
    /**
     * Search
     */
    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: AnyCancellable?
    @Published var searchQuery: String = ""
    private var lastQuery: String?
    
    /**
     * Prompt ratings
     */
    var requestReview: (() -> Void)?
    
    /**
     * Upgrade guest account sheet
     */
    @Published var isPresentedCreateAccount: Bool = false
    
    
    var api: SdkApi
    var device: SdkDeviceRemote?
    var connectViewController: SdkConnectViewController?
    
    init(api: SdkApi, device: SdkDeviceRemote?, connectViewController: SdkConnectViewController?) {
        self.api = api
        self.connectViewController = connectViewController
        self.addGridListener()
        self.addConnectionStatusListener()
        self.addSelectedLocationListener()
        
        self.updateConnectionStatus()
        
        self.selectedProvider = device?.getConnectLocation()
        
        // when search changes
        // debounce and fire search
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.performSearch(query)
            }
            .store(in: &cancellables)
        
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
    

// MARK: providers list
extension ConnectViewModel {
    
    private func flattenConnectLocationList(_ connectLocationList: SdkConnectLocationList) -> [SdkConnectLocation] {
        
        var locations: [SdkConnectLocation] = []
        let len = connectLocationList.len()
        
        // ensure not an empty list
        if len > 0 {
            
            // loop
            for i in 0..<len {
                
                // unwrap connect location
                if let location = connectLocationList.get(i) {
                    
                    // append to the connect location array
                    locations.append(location)
                }
            }
        }
        
        return locations
        
    }
    
    private func searchProviders(_ query: String) async -> Result<Void, Error> {
        do {
            
            providersLoading = true
            
            let result: SdkFilteredLocations = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = FindLocationsCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    let filteredLocations = SdkGetFilteredLocationsFromResult(result, query)
                    
                    guard let filteredLocations = filteredLocations else {
                        continuation.resume(throwing: FetchProvidersError.noProvidersFound)
                        return
                    }
                    
                    continuation.resume(returning: filteredLocations)
                    
                }
                
                let args = SdkFindLocationsArgs()
                args.query = query
                
                api.findProviderLocations(args, callback: callback)
            }
            
            self.handleLocations(result)
            
            providersLoading = false
            
            return .success(())
            
        } catch (let error) {
            providersLoading = false
            return .failure(error)
        }
    }
    
    private func handleLocations(_ result: SdkFilteredLocations) {
        DispatchQueue.main.async {
            self.providerCountries.removeAll()
            self.providerPromoted.removeAll()
            self.providerDevices.removeAll()
            self.providerRegions.removeAll()
            self.providerCities.removeAll()
            self.providerBestSearchMatches.removeAll()
            
            if let countries = result.countries {
                self.providerCountries.append(contentsOf: self.flattenConnectLocationList(countries))
            }
            
            if let promoted = result.promoted {
                self.providerPromoted.append(contentsOf: self.flattenConnectLocationList(promoted))
            }
            
            if let devices = result.devices {
                self.providerDevices.append(contentsOf: self.flattenConnectLocationList(devices))
            }
            
            if let regions = result.regions {
                self.providerRegions.append(contentsOf: self.flattenConnectLocationList(regions))
            }
            
            if let cities = result.cities {
                self.providerCities.append(contentsOf: self.flattenConnectLocationList(cities))
            }
            
            if let bestMatches = result.bestMatches {
                self.providerBestSearchMatches.append(contentsOf: self.flattenConnectLocationList(bestMatches))
            }
            
        }
    }
    
    private func performSearch(_ query: String) {
        if query != self.lastQuery {
         
            Task {
                let _ = await filterLocations(query)
                self.lastQuery = query
            }
            
        }
    }
    
    func filterLocations(_ query: String) async -> Result<Void, Error> {
        
        if query.isEmpty {
            return await self.getAllProviders()
        } else {
            return await searchProviders(query)
        }
        
    }
    
    private func getAllProviders() async -> Result<Void, Error> {
        
        do {
            
            providersLoading = true
            
            let result: SdkFilteredLocations = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = FindLocationsCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    let filter = ""
                    let filteredLocations = SdkGetFilteredLocationsFromResult(result, filter)
                    
                    guard let filteredLocations = filteredLocations else {
                        continuation.resume(throwing: FetchProvidersError.noProvidersFound)
                        return
                    }
                    
                    continuation.resume(returning: filteredLocations)
                    
                }
                
                api.getProviderLocations(callback)
            }
            
            self.handleLocations(result)
            
            providersLoading = false
            
            return .success(())
            
        } catch (let error) {
            
            providersLoading = false
            
            return .failure(error)
        }
        
    }
    
}

/**
 * Grid
 */

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
        
           self.grid = self.connectViewController?.getGrid()
           
           if let grid = self.grid {
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
