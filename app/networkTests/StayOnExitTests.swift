//
//  StayOnExitTests.swift
//  networkTests
//
//  "Stay on this exit" in Provider Locations: which rows offer it, and the
//  one-provider location it connects to.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct StayOnExitTests {

    private static let clientIdString = "018f2b6e-3c4d-7a8b-9c0d-1e2f3a4b5c6d"

    private func parseId(_ idString: String) throws -> SdkId {
        var parseError: NSError?
        return try #require(SdkParseId(idString, &parseError))
    }

    private func row(
        clientId: SdkId,
        country: String = "",
        countryCode: String = "",
        region: String = "",
        city: String = "",
        hasLocation: Bool = true
    ) -> ProviderLocationRow {
        ProviderLocationRow(
            clientId: clientId,
            country: country,
            countryCode: countryCode,
            region: region,
            city: city,
            hasLocation: hasLocation,
            lat: nil,
            lon: nil,
            connectedSinceMillis: 0,
            ipFamilyLabel: SdkIpFamilyLabelBoth
        )
    }

    @Test func shortClientIdKeepsTheFirstAndLastFour() {
        #expect(shortClientId(Self.clientIdString) == "018f…5c6d")
        #expect(shortClientId(" \(Self.clientIdString) ") == "018f…5c6d")
        #expect(shortClientId("abcd1234") == "abcd1234")
    }

    @Test func nameIsTheShortIdThenCityAndCountry() throws {
        let clientId = try parseId(Self.clientIdString)
        #expect(
            stayOnExitName(row(clientId: clientId, country: "Germany", region: "Land Berlin", city: "Berlin"))
                == "018f…5c6d · Berlin, Germany"
        )
    }

    @Test func nameUsesTheRegionWhenTheCityIsUnknown() throws {
        let clientId = try parseId(Self.clientIdString)
        #expect(
            stayOnExitName(row(clientId: clientId, country: "United States", region: "California"))
                == "018f…5c6d · California, United States"
        )
        #expect(stayOnExitName(row(clientId: clientId, country: "Iceland")) == "018f…5c6d · Iceland")
    }

    @Test func nameIsTheShortIdWhenTheLocationIsUnknown() throws {
        let clientId = try parseId(Self.clientIdString)
        #expect(stayOnExitName(row(clientId: clientId)) == "018f…5c6d")
        #expect(stayOnExitName(row(clientId: clientId, country: "Japan", hasLocation: false)) == "018f…5c6d")
    }

    // The location is the one provider, by client id, and a public exit: a
    // network peer location would egress under the network provide mode.
    @Test func locationIsTheProviderAloneAsAPublicExit() throws {
        let clientId = try parseId(Self.clientIdString)
        let location = stayOnExitLocation(
            row(clientId: clientId, country: "Japan", countryCode: "jp", region: "Osaka", city: "Osaka")
        )
        let locationId = try #require(location.connectLocationId)
        #expect(locationId.clientId?.idStr == Self.clientIdString)
        #expect(locationId.locationId == nil)
        #expect(locationId.locationGroupId == nil)
        #expect(!locationId.bestAvailable)
        #expect(location.isDevice())
        #expect(!location.networkPeer)
        #expect(location.name == "018f…5c6d · Osaka, Japan")
        #expect(location.city == "Osaka")
        #expect(location.region == "Osaka")
        #expect(location.country == "Japan")
        #expect(location.countryCode == "jp")
    }

    @Test func onlyTheSelectedRowOffersToStay() throws {
        let selected = row(clientId: try parseId(Self.clientIdString))
        let other = row(clientId: try #require(SdkNewId()))
        #expect(stayOnExitState(selected, selectedClientId: selected.id, stayingClientId: nil) == .offer)
        #expect(stayOnExitState(other, selectedClientId: selected.id, stayingClientId: nil) == .none)
        // nothing selected (no providers) offers nothing
        #expect(stayOnExitState(selected, selectedClientId: nil, stayingClientId: nil) == .none)
    }

    @Test func theProviderAlreadyStayedOnSaysSoInsteadOfOffering() throws {
        let stayed = row(clientId: try parseId(Self.clientIdString))
        let other = row(clientId: try #require(SdkNewId()))
        // selected or not, the stayed provider never offers itself again
        #expect(stayOnExitState(stayed, selectedClientId: stayed.id, stayingClientId: stayed.id) == .staying)
        #expect(stayOnExitState(stayed, selectedClientId: other.id, stayingClientId: stayed.id) == .staying)
        // another selected provider can still be stayed on instead
        #expect(stayOnExitState(other, selectedClientId: other.id, stayingClientId: stayed.id) == .offer)
    }

    @Test func clientIdsMatchIgnoringCase() throws {
        let stayed = row(clientId: try parseId(Self.clientIdString))
        #expect(
            stayOnExitState(stayed, selectedClientId: nil, stayingClientId: Self.clientIdString.uppercased())
                == .staying
        )
        #expect(
            stayOnExitState(stayed, selectedClientId: Self.clientIdString.uppercased(), stayingClientId: nil)
                == .offer
        )
    }
}
