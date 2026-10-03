//
//  BlockedLocationsErrorTests.swift
//  networkTests
//
//  Removing a blocked location is optimistic: on an API failure the row comes
//  back. The view model set an error message for that, but the screen never
//  showed it, so the row silently reappeared. A failed list fetch also showed
//  "No blocked locations" as if the list were empty.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct BlockedLocationsErrorTests {

    private struct ApiError: Error {}

    /// The mock api with a stored blocked list and switchable failures.
    private final class BlockedLocationsApi: MockUrApiService {
        var failUnblock = false
        var failFetch = false
        var blocked: [SdkBlockedLocation] = []

        override func unblockLocation(_ locationId: SdkId) async throws -> SdkNetworkUnblockLocationResult {
            if failUnblock {
                throw ApiError()
            }
            blocked.removeAll { locationId.cmp($0.locationId) == 0 }
            return SdkNetworkUnblockLocationResult()
        }

        override func getBlockedLocations() async throws -> SdkGetNetworkBlockedLocationsResult {
            if failFetch {
                throw ApiError()
            }
            let list = SdkNewBlockedLocationsList()
            for location in blocked {
                list?.add(location)
            }
            let result = SdkGetNetworkBlockedLocationsResult()
            result.blockedLocations = list
            return result
        }
    }

    private static func location(_ name: String) -> SdkBlockedLocation {
        let location = SdkBlockedLocation()
        location.locationId = SdkNewId()
        location.locationName = name
        location.locationType = SdkLocationTypeCountry
        location.countryCode = "xx"
        return location
    }

    @Test func aFailedFetchIsAnErrorNotAnEmptyList() async {
        let api = BlockedLocationsApi()
        api.failFetch = true
        // a long error display so the published error cannot clear mid-test
        let viewModel = BlockedLocationsView.ViewModel(api: api, countries: [], processingErrorSeconds: 3600)
        await viewModel.initialFetch?.value

        #expect(viewModel.blockedLocations.isEmpty)
        #expect(viewModel.loadFailed)

        api.failFetch = false
        api.blocked = [Self.location("Testland")]
        await viewModel.fetchBlockedLocations()
        #expect(!viewModel.loadFailed)
        #expect(viewModel.blockedLocations.count == 1)
    }

    @Test func aFailedRemovalRestoresTheRowAndPublishesTheError() async throws {
        let api = BlockedLocationsApi()
        let blocked = Self.location("Testland")
        api.blocked = [blocked]
        // a long error display so the published error cannot clear mid-test
        let viewModel = BlockedLocationsView.ViewModel(api: api, countries: [], processingErrorSeconds: 3600)
        await viewModel.initialFetch?.value
        #expect(viewModel.blockedLocations.count == 1)

        api.failUnblock = true
        let removal = viewModel.removeFromList(try #require(blocked.locationId))
        #expect(viewModel.blockedLocations.isEmpty)

        await removal.value
        #expect(viewModel.processingErrorMsg == viewModel.unblockLocationErrorMsg)
        #expect(viewModel.blockedLocations.count == 1)
    }

    @Test func theScreenShowsTheErrorAndTheLoadFailure() throws {
        // …/apple/app/networkTests/BlockedLocationsErrorTests.swift -> the view source
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("network/Main/Account/BlockedLocations/BlockedLocationsView.swift")
        let text = try String(contentsOf: view, encoding: .utf8)
        // the error the view model publishes on a failed add or remove is rendered
        #expect(text.contains("viewModel.processingErrorMsg"))
        #expect(text.contains("viewModel.loadFailed"))
    }
}
