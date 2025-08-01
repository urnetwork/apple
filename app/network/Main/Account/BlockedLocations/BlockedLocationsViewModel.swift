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

        var api: UrApiServiceProtocol

        @Published var isInitializing: Bool = true
        @Published var isLoading: Bool = false
        @Published var isProcessingLocation: Bool = false
        @Published var processingErrorMsg: LocalizedStringKey? = nil
        @Published var blockedLocations: [SdkBlockedLocation] = []
        @Published private(set) var displayLocationSearch: Bool = false

        let blockLocationErrorMsg: LocalizedStringKey =
            "Blocked location could not be added. Please try again later."
        let unblockLocationErrorMsg: LocalizedStringKey =
            "Blocked location could not be removed. Please try again later."

        init(api: UrApiServiceProtocol) {
            self.api = api

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

                self.blockedLocations = blockedLocations

                isLoading = false
            } catch (let error) {
                print("error fetching blocked locations: \(error)")
                isLoading = false
            }

        }

        func blockLocation(locationId: SdkId, locationName: String) async {

            if isProcessingLocation {
                return
            }

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

                let blockedLocation = SdkBlockedLocation()
                blockedLocation.locationName = locationName
                blockedLocation.locationId = locationId

                self.blockedLocations.append(blockedLocation)

                isProcessingLocation = false
            } catch (let error) {
                print("error blocking location: \(error)")
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

            //            if isProcessingLocation {
            //                return
            //            }
            //
            //            isProcessingLocation = true

            do {

                let result = try await api.unblockLocation(locationId)

                if result.error != nil {
                    print(
                        "unblock location result error: \(String(describing: result.error?.message))"
                    )
                    self.setProcessingError(unblockLocationErrorMsg)
                    //                    isProcessingLocation = false

                    await self.fetchBlockedLocations()
                }

                //                isProcessingLocation = false
            } catch (let error) {
                print("error unblocking location: \(error)")
                await self.fetchBlockedLocations()
                self.setProcessingError(unblockLocationErrorMsg)
                //                isProcessingLocation = false
            }
        }

        private func setProcessingError(_ msg: LocalizedStringKey?) {
            processingErrorMsg = msg

            // clear after 5 seconds

        }

        func setDisplayLocationSearch(_ display: Bool) {
            displayLocationSearch = display
        }

    }
}
