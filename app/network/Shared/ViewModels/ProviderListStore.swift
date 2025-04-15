//
//  ProviderListStore.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/04/15.
//

import Foundation
import URnetworkSdk
import Combine

@MainActor
public final class ProviderListStore: ObservableObject {
    
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
     * Search
     */
    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: AnyCancellable?
    @Published var searchQuery: String = ""
    private var lastQuery: String?
    
    private var api: SdkApi?
    
    init(api: SdkApi) {
        self.api = api
        
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.performSearch(query)
            }
            .store(in: &cancellables)
        
    }
    
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
                
                if let api = self.api {
                    api.findProviderLocations(args, callback: callback)
                }
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
        
        let countries = result.countries.flatMap { flattenConnectLocationList($0) } ?? []
        let promoted = result.promoted.flatMap { flattenConnectLocationList($0) } ?? []
        let devices = result.devices.flatMap { flattenConnectLocationList($0) } ?? []
        let regions = result.regions.flatMap { flattenConnectLocationList($0) } ?? []
        let cities = result.cities.flatMap { flattenConnectLocationList($0) } ?? []
        let bestMatches = result.bestMatches.flatMap { flattenConnectLocationList($0) } ?? []
        
        self.providerCountries = countries
        self.providerPromoted = promoted
        self.providerDevices = devices
        self.providerRegions = regions
        self.providerCities = cities
        self.providerBestSearchMatches = bestMatches
        
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
                
                if let api = self.api {
                    api.getProviderLocations(callback)
                }
    
            }
            
            self.handleLocations(result)
            
            providersLoading = false
            
            return .success(())
            
        } catch (let error) {
            
            providersLoading = false
            
            return .failure(error)
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
    
}

private class FindLocationsCallback: SdkCallback<SdkFindLocationsResult, SdkFindLocationsCallbackProtocol>, SdkFindLocationsCallbackProtocol {
    func result(_ result: SdkFindLocationsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum FetchProvidersError: Error {
    case noProvidersFound
}
