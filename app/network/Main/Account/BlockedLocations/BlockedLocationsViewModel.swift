//
//  BlockedLocationsViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/29/25.
//

import Foundation
import SwiftUI
import URnetworkSdk

extension BlockedLocationsView {

    @MainActor
    class ViewModel: ObservableObject {

        let api: UrApiServiceProtocol

        @Published var isInitializing: Bool = true
        @Published var isLoading: Bool = false
        @Published var isProcessingLocation: Bool = false
        @Published var processingErrorMsg: LocalizedStringKey? = nil
        @Published var blockedLocations: [SdkBlockedLocation] = []
        @Published private(set) var displayLocationSearch: Bool = false
        
        @Published var displayProviderSheet: Bool = false
        @Published var searchCountry: String = "" {
            didSet {
                filterCountries(searchCountry)
            }
        }
        
        private let allCountries: [SdkConnectLocation]
        @Published var availableCountries: [SdkConnectLocation]

        let blockLocationErrorMsg: LocalizedStringKey =
            "Blocked location could not be added. Please try again later."
        let unblockLocationErrorMsg: LocalizedStringKey =
            "Blocked location could not be removed. Please try again later."

        init(
            api: UrApiServiceProtocol,
            countries: [SdkConnectLocation]
        ) {
            self.api = api
            
            self.allCountries = countries.sorted{ $0.name < $1.name }
            self.availableCountries = allCountries
            

            Task {
                await fetchBlockedLocations()
                isInitializing = false
            }

        }

        func fetchBlockedLocations() async {

            if isLoading {
                return
            }

            isLoading = true

            do {

                let result = try await api.getBlockedLocations()

                // loop locations
                let len = result.blockedLocations?.len() ?? 0
                var blockedLocations: [SdkBlockedLocation] = []

                // ensure not an empty list
                if len > 0 {

                    // loop
                    for i in 0..<len {

                        // unwrap connect location
                        if let location = result.blockedLocations?.get(i) {

                            // append to the connect location array
                            blockedLocations.append(location)
                        }
                    }
                }
                
                // sort by name
                self.blockedLocations = blockedLocations.sorted { $0.locationName < $1.locationName }

                isLoading = false
            } catch (let error) {
                print("error fetching blocked locations: \(error)")
                isLoading = false
            }

        }
        
        func isBlocked(locationId: SdkId) -> Bool {
            blockedLocations.contains(where: { (($0.locationId?.cmp(locationId)) == 0) == true })
        }
        
        func blockLocation(
            locationId: SdkId?,
            locationName: String,
            countryCode: String
        ) {
            
            if isProcessingLocation {
                return
            }
            
            guard let locationId else {
                return
            }
            
            if (self.isBlocked(locationId: locationId)) {
                return
            }
            
            let newBlockedLocation = SdkBlockedLocation()
            newBlockedLocation.locationName = locationName
            newBlockedLocation.locationId = locationId
            newBlockedLocation.locationType = SdkLocationTypeCountry
            newBlockedLocation.countryCode = countryCode
            
            
            var blockedLocations = self.blockedLocations
            blockedLocations.append(newBlockedLocation)
            
            self.blockedLocations = blockedLocations.sorted { $0.locationName < $1.locationName }
            
            Task {
                await blockLocation(locationId: locationId, locationName: locationName)
            }
            
        }

        private func blockLocation(locationId: SdkId, locationName: String) async {

            isProcessingLocation = true

            do {
                let result = try await api.blockLocation(locationId)

                if result.error != nil {
                    print(
                        "block location result error: \(String(describing: result.error?.message))")
                    self.setProcessingError(blockLocationErrorMsg)
                    isProcessingLocation = false
                    return
                }

                isProcessingLocation = false
            } catch (let error) {
                print("error blocking location: \(error)")
                self.blockedLocations.removeAll(where: { locationId.cmp($0.locationId) == 0 })
                self.setProcessingError(blockLocationErrorMsg)
                isProcessingLocation = false
            }

        }

        func removeFromList(_ locationId: SdkId) {

            self.blockedLocations.removeAll(where: { locationId.cmp($0.locationId) == 0 })

            Task {
                await self.unblockLocation(locationId)
            }
        }

        private func unblockLocation(_ locationId: SdkId) async {

            do {

                let result = try await api.unblockLocation(locationId)

                if result.error != nil {
                    print(
                        "unblock location result error: \(String(describing: result.error?.message))"
                    )
                    self.setProcessingError(unblockLocationErrorMsg)

                    await self.fetchBlockedLocations()
                }

            } catch (let error) {
                print("error unblocking location: \(error)")
                await self.fetchBlockedLocations()
                self.setProcessingError(unblockLocationErrorMsg)
            }
        }

        private func setProcessingError(_ msg: LocalizedStringKey?) {
            processingErrorMsg = msg

            // clear after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.processingErrorMsg = nil
            }

        }

        func setDisplayLocationSearch(_ display: Bool) {
            displayLocationSearch = display
        }
        
        func filterCountries(_ text: String) {
            
            if text.isEmpty {
                self.availableCountries = self.allCountries
            } else {
                self.availableCountries = self.allCountries.filter {
                    $0.name.lowercased().contains(text.lowercased())
                }
            }
            
        }

    }
}
