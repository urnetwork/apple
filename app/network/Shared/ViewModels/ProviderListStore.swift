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
    @Published private(set) var providerDevices: [SdkConnectLocation] = []
    @Published private(set) var providerRegions: [SdkConnectLocation] = []
    @Published private(set) var providerCities: [SdkConnectLocation] = []
    @Published private(set) var providerBestSearchMatches: [SdkConnectLocation] = []
    
    /**
     * Provider loading state
     */
    @Published private(set) var providersLoading: Bool = false

    // A same-query refresh keeps usable rows on screen. Query changes clear
    // those rows before loading, so results from a different query never stand
    // in for the pending response.
    var showLoadingPlaceholder: Bool {
        providersLoading && providerCountries.isEmpty && providerDevices.isEmpty
            && providerRegions.isEmpty && providerCities.isEmpty
            && providerBestSearchMatches.isEmpty
    }
    
    /**
     * Search
     */
    private var cancellables = Set<AnyCancellable>()
    @Published var searchQuery: String = ""
    private var lastQuery: String?
    
    private var currentSearchTask: Task<Void, Never>?
    private var requestGeneration: Int = 0
    private var activeRequest: (
        query: String, generation: Int, task: Task<Result<Void, Error>, Never>
    )?
    
    private var urApiService: UrApiServiceProtocol
    
    init(urApiService: UrApiServiceProtocol) {
        self.urApiService = urApiService
        
        $searchQuery
            // Each visible picker owns its first fetch. @Published's initial
            // empty value otherwise races the sheet's onAppear request.
            .dropFirst()
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
    
    private func handleLocations(_ result: SdkFilteredLocations) {
        
        let countries = result.countries.flatMap { flattenConnectLocationList($0) } ?? []
        let devices = result.devices.flatMap { flattenConnectLocationList($0) } ?? []
        let regions = result.regions.flatMap { flattenConnectLocationList($0) } ?? []
        let cities = result.cities.flatMap { flattenConnectLocationList($0) } ?? []
        let bestMatches = result.bestMatches.flatMap { flattenConnectLocationList($0) } ?? []
        
        self.providerCountries = countries
        self.providerDevices = devices
        self.providerRegions = regions
        self.providerCities = cities
        self.providerBestSearchMatches = bestMatches
        
    }
    
    func filterLocations(_ query: String) async -> Result<Void, Error> {
        guard !Task.isCancelled else { return .failure(CancellationError()) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let request = activeRequest, request.query == query {
            // An appearance, refresh and debounced edit can share one fetch.
            // Canceling a waiter does not cancel another waiter's request.
            return await request.task.value
        }

        activeRequest?.task.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        if lastQuery != query {
            providerCountries = []
            providerDevices = []
            providerRegions = []
            providerCities = []
            providerBestSearchMatches = []
            lastQuery = nil
        }
        providersLoading = true

        let task = Task { @MainActor [self] () -> Result<Void, Error> in
            defer {
                if activeRequest?.generation == generation {
                    activeRequest = nil
                    providersLoading = false
                }
            }
            do {
                try Task.checkCancellation()
                let result: SdkFilteredLocations
                if query.isEmpty {
                    result = try await urApiService.getAllProviders()
                } else {
                    result = try await urApiService.searchProviders(query)
                }
                // The SDK callback uses its API's lifetime, so cancellation
                // may arrive before the callback. Fence publication as well
                // as the spinner, including a late result for an old query.
                guard !Task.isCancelled,
                      activeRequest?.generation == generation else {
                    return .failure(CancellationError())
                }
                handleLocations(result)
                lastQuery = query
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        activeRequest = (query, generation, task)
        return await task.value
    }
    
    private func performSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != self.lastQuery {
            // Cancel any previous search task
            currentSearchTask?.cancel()
            
            // Create a new search task
            currentSearchTask = Task {
                let _ = await filterLocations(query)
            }
        }
    }
    
}
