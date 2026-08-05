//
//  ProviderLocationLabelTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct ProviderLocationLabelTests {

    private func row(
        country: String = "",
        countryCode: String = "",
        region: String = "",
        city: String = "",
        hasLocation: Bool = true,
        lat: Double? = nil,
        lon: Double? = nil,
        connectedSinceMillis: Int64 = 0
    ) -> ProviderLocationRow {
        ProviderLocationRow(
            clientId: SdkNewId()!,
            country: country,
            countryCode: countryCode,
            region: region,
            city: city,
            hasLocation: hasLocation,
            lat: lat,
            lon: lon,
            connectedSinceMillis: connectedSinceMillis
        )
    }

    @Test func placeLabelReadsCityRegionCountry() {
        let label = providerPlaceLabel(
            row(country: "United States", region: "California", city: "San Francisco")
        )
        #expect(label == "San Francisco, California, United States")
    }

    @Test func placeLabelOmitsThePartsTheServerDoesNotKnow() {
        #expect(providerPlaceLabel(row(country: "Japan", region: "Tokyo")) == "Tokyo, Japan")
        #expect(providerPlaceLabel(row(country: "Japan")) == "Japan")
    }

    @Test func placeLabelFallsBackWhenTheLocationIsUnknown() {
        // localized, so only the fallback behaviour is asserted: a provider
        // without a location never renders an empty place line, and never
        // renders the parts of a location it does not have
        let unknown = providerPlaceLabel(row(country: "Japan", hasLocation: false))
        #expect(!unknown.isEmpty)
        #expect(unknown != "Japan")
        #expect(providerPlaceLabel(row()) == unknown)
    }

    @Test func coordinatesLabelIsFourDecimalPlaces() {
        #expect(
            providerCoordinatesLabel(row(lat: 37.7749295, lon: -122.4194155))
                == "37.7749, -122.4194"
        )
        #expect(providerCoordinatesLabel(row(lat: 0, lon: 0)) == "0.0000, 0.0000")
    }

    @Test func coordinatesLabelIsAnEmDashWithoutCoordinates() {
        #expect(providerCoordinatesLabel(row()) == "—")
        #expect(providerCoordinatesLabel(row(lat: 10)) == "—")
    }

    @Test func connectedDurationIsEmptyWithoutAStamp() {
        #expect(providerConnectedDurationLabel(row(), now: Date()) == "")
    }

    @Test func connectedDurationCountsFromTheStamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)

        // the exact text is localized; what must hold is that each band is
        // non-empty, distinct, and moves with elapsed time
        let seconds = providerConnectedDurationLabel(
            row(connectedSinceMillis: nowMillis - 42_000), now: now
        )
        let minutes = providerConnectedDurationLabel(
            row(connectedSinceMillis: nowMillis - 24 * 60_000), now: now
        )
        let hours = providerConnectedDurationLabel(
            row(connectedSinceMillis: nowMillis - (3 * 3_600_000 + 24 * 60_000)), now: now
        )
        #expect(seconds.contains("42"))
        #expect(minutes.contains("24"))
        #expect(hours.contains("3") && hours.contains("24"))
        #expect(seconds != minutes && minutes != hours)

        // a stamp in the future clamps to zero rather than going negative
        let future = providerConnectedDurationLabel(
            row(connectedSinceMillis: nowMillis + 10_000), now: now
        )
        #expect(future.contains("0"))
        #expect(!future.contains("-"))
    }
}
