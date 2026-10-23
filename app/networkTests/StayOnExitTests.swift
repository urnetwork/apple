//
//  StayOnExitTests.swift
//  networkTests
//
//  "Stay on this exit" in Provider Locations: which rows offer it, and the
//  one-provider location it connects to, through the row's extender alone
//  when one carries it (EXTENDER.md K10).
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct StayOnExitTests {

    private static let clientIdString = "018f2b6e-3c4d-7a8b-9c0d-1e2f3a4b5c6d"
    private static let extender = ProviderExtender(ip: "203.0.113.7", colorHex: "e0115f")
    private static let migratingExtender = ProviderExtender(ip: "2001:db8::7", colorHex: "11a0e0")

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
        hasLocation: Bool = true,
        extenders: [ProviderExtender] = []
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
            ipFamilyLabel: SdkIpFamilyLabelBoth,
            extenders: extenders
        )
    }

    // the state on a device that keeps the pin, unless a test says otherwise
    private func state(
        _ row: ProviderLocationRow,
        selectedClientId: String?,
        stayingClientId: String?,
        stayingExtenderIp: String? = nil,
        pinsExtender: Bool = true
    ) -> StayOnExitState {
        stayOnExitState(
            row,
            selectedClientId: selectedClientId,
            stayingClientId: stayingClientId,
            stayingExtenderIp: stayingExtenderIp,
            pinsExtender: pinsExtender
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
            row(clientId: clientId, country: "Japan", countryCode: "jp", region: "Osaka", city: "Osaka"),
            extenderIp: nil
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
        #expect(location.extenderIp.isEmpty)
        #expect(stayOnExitPinnedExtenderIp(location) == nil)
    }

    @Test func onlyTheSelectedRowOffersToStay() throws {
        let selected = row(clientId: try parseId(Self.clientIdString))
        let other = row(clientId: try #require(SdkNewId()))
        #expect(state(selected, selectedClientId: selected.id, stayingClientId: nil) == .offer(extenderIp: nil))
        #expect(state(other, selectedClientId: selected.id, stayingClientId: nil) == .none)
        // nothing selected (no providers) offers nothing
        #expect(state(selected, selectedClientId: nil, stayingClientId: nil) == .none)
    }

    @Test func theProviderAlreadyStayedOnSaysSoInsteadOfOffering() throws {
        let stayed = row(clientId: try parseId(Self.clientIdString))
        let other = row(clientId: try #require(SdkNewId()))
        // selected or not, the stayed provider never offers itself again
        #expect(state(stayed, selectedClientId: stayed.id, stayingClientId: stayed.id) == .staying(extenderIp: nil))
        #expect(state(stayed, selectedClientId: other.id, stayingClientId: stayed.id) == .staying(extenderIp: nil))
        // another selected provider can still be stayed on instead
        #expect(state(other, selectedClientId: other.id, stayingClientId: stayed.id) == .offer(extenderIp: nil))
    }

    @Test func clientIdsMatchIgnoringCase() throws {
        let stayed = row(clientId: try parseId(Self.clientIdString))
        #expect(
            state(stayed, selectedClientId: nil, stayingClientId: Self.clientIdString.uppercased())
                == .staying(extenderIp: nil)
        )
        #expect(
            state(stayed, selectedClientId: Self.clientIdString.uppercased(), stayingClientId: nil)
                == .offer(extenderIp: nil)
        )
    }

    // MARK: - the extender pin (K10)

    @Test func aStayOnARowThroughAnExtenderPinsIt() throws {
        let extended = row(clientId: try parseId(Self.clientIdString), extenders: [Self.extender])
        #expect(
            state(extended, selectedClientId: extended.id, stayingClientId: nil)
                == .offer(extenderIp: Self.extender.ip)
        )
        let location = stayOnExitLocation(extended, extenderIp: Self.extender.ip)
        #expect(location.extenderIp == Self.extender.ip)
        #expect(location.connectLocationId?.clientId?.idStr == Self.clientIdString)
        #expect(stayOnExitPinnedExtenderIp(location) == Self.extender.ip)
    }

    // across a migration the row carries two; the stay pins the first, the
    // dot's outermost ring, and its text names that one
    @Test func aRowCarryingTwoExtendersPinsTheFirst() throws {
        let migrating = row(
            clientId: try parseId(Self.clientIdString),
            extenders: [Self.extender, Self.migratingExtender]
        )
        #expect(
            state(migrating, selectedClientId: migrating.id, stayingClientId: nil)
                == .offer(extenderIp: Self.extender.ip)
        )
    }

    @Test func aDirectRowOffersTheStayAlone() throws {
        let direct = row(clientId: try parseId(Self.clientIdString))
        #expect(state(direct, selectedClientId: direct.id, stayingClientId: nil) == .offer(extenderIp: nil))
    }

    // an extension that would drop the pin is offered the stay alone, which is
    // what it keeps
    @Test func aDeviceWithoutThePinOffersTheStayAlone() throws {
        let extended = row(clientId: try parseId(Self.clientIdString), extenders: [Self.extender])
        #expect(
            state(extended, selectedClientId: extended.id, stayingClientId: nil, pinsExtender: false)
                == .offer(extenderIp: nil)
        )
    }

    // the staying line names the pinned extender, selected or not, and keeps
    // naming it while the provider is reached some other way (a p2p route,
    // which the pin does not cover) rather than offering the stay again
    @Test func theStayNamesItsPinnedExtender() throws {
        let stayed = row(clientId: try parseId(Self.clientIdString), extenders: [Self.extender])
        let other = row(clientId: try #require(SdkNewId()))
        #expect(
            state(stayed, selectedClientId: stayed.id, stayingClientId: stayed.id, stayingExtenderIp: Self.extender.ip)
                == .staying(extenderIp: Self.extender.ip)
        )
        #expect(
            state(stayed, selectedClientId: other.id, stayingClientId: stayed.id, stayingExtenderIp: Self.extender.ip)
                == .staying(extenderIp: Self.extender.ip)
        )
        let p2p = row(clientId: try parseId(Self.clientIdString))
        #expect(
            state(p2p, selectedClientId: p2p.id, stayingClientId: p2p.id, stayingExtenderIp: Self.extender.ip)
                == .staying(extenderIp: Self.extender.ip)
        )
    }

    // a stay from before the pin, on a provider now reached through an
    // extender, still says it stays rather than offering itself again
    @Test func anEarlierStayIsNotOfferedThePin() throws {
        let stayed = row(clientId: try parseId(Self.clientIdString), extenders: [Self.extender])
        #expect(
            state(stayed, selectedClientId: stayed.id, stayingClientId: stayed.id)
                == .staying(extenderIp: nil)
        )
    }

    @Test func onlyAClientIdLocationCarriesAPin() throws {
        #expect(stayOnExitPinnedExtenderIp(nil) == nil)

        let stayed = stayOnExitLocation(row(clientId: try parseId(Self.clientIdString)), extenderIp: " 203.0.113.7 ")
        #expect(stayOnExitPinnedExtenderIp(stayed) == "203.0.113.7")
        stayed.extenderIp = ""
        #expect(stayOnExitPinnedExtenderIp(stayed) == nil)

        let bestAvailable = SdkConnectLocation()
        let bestAvailableId = SdkConnectLocationId()
        bestAvailableId.bestAvailable = true
        bestAvailable.connectLocationId = bestAvailableId
        bestAvailable.extenderIp = Self.extender.ip
        #expect(stayOnExitPinnedExtenderIp(bestAvailable) == nil)
    }

    @Test func anExtenderAddressIsIsolatedInsideASentence() {
        #expect(stayOnExitExtenderAddress("2001:db8::7") == "\u{2068}2001:db8::7\u{2069}")
    }
}
