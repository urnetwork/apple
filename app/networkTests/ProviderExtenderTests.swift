//
//  ProviderExtenderTests.swift
//  networkTests
//

import CoreGraphics
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// The extenders on the provider details rows (connect/EXTENDER.md K9): the
/// SDK's paired address and color lists, the row identity, and the rings on
/// the row and globe dots.
struct ProviderExtenderTests {

    private static let first = ProviderExtender(ip: "203.0.113.7", colorHex: "AABBCC")
    private static let second = ProviderExtender(ip: "2001:db8::5", colorHex: "DDEEFF")

    private func row(clientId: SdkId = SdkNewId()!, extenders: [ProviderExtender]) -> ProviderLocationRow {
        ProviderLocationRow(
            clientId: clientId,
            country: "",
            countryCode: "us",
            region: "",
            city: "",
            hasLocation: true,
            lat: nil,
            lon: nil,
            connectedSinceMillis: 0,
            ipFamilyLabel: "",
            extenders: extenders
        )
    }

    @Test func pairsTheSdkListsByIndex() {
        let extenders = providerExtenders(ips: "203.0.113.7,2001:db8::5", colorHexes: "AABBCC,DDEEFF")
        #expect(extenders == [Self.first, Self.second])
    }

    @Test func aDirectRouteHasNoExtenders() {
        #expect(providerExtenders(ips: "", colorHexes: "").isEmpty)
    }

    // The SDK keeps the two lists the same length; an unpaired tail is dropped
    // rather than drawn in a made-up color.
    @Test func anUnpairedTailIsDropped() {
        #expect(providerExtenders(ips: "203.0.113.7,198.51.100.2", colorHexes: "AABBCC") == [Self.first])
    }

    // The color is the SDK's for the address (K3), never one computed here.
    @Test func theColorIsTheSdks() {
        let ip = "203.0.113.7"
        let extenders = providerExtenders(ips: ip, colorHexes: SdkGetExtenderColorHex(ip))
        #expect(extenders.first?.colorHex == SdkGetExtenderColorHex(ip))
    }

    // A transport migration changes only the extenders, so they are part of the
    // row's value: an equal row would not be republished.
    @Test func extendersArePartOfTheRow() {
        let clientId = SdkNewId()!
        let extended = row(clientId: clientId, extenders: [Self.first])
        #expect(row(clientId: clientId, extenders: []) != extended)
        #expect(row(clientId: clientId, extenders: [Self.first, Self.second]) != extended)
        #expect(row(clientId: clientId, extenders: [Self.first]) == extended)
    }

    // The row dot (40 pt on iOS, 30 pt on macOS) has room for all three rings
    // at the connect grid's fixed geometry (K2); a fourth extender dashes the
    // third ring.
    @Test func theRowDotHoldsThreeRings() {
        for diameter in [CGFloat(40), CGFloat(30)] {
            let geometry = extenderRingGeometry(
                cellSize: diameter,
                colorHexes: ["AABBCC", "DDEEFF", "112233", "445566"]
            )
            #expect(geometry.rings.count == 3)
            #expect(geometry.rings.last?.dashed == true)
            #expect(geometry.strokeWidth == extenderRingStrokeWidth)
            #expect(geometry.dotDiameter == diameter - 6 * extenderRingStep)
            // the outermost ring's outer edge is the dot's edge
            #expect(geometry.rings[0].diameter + extenderRingStrokeWidth == diameter)
        }
    }

    // The globe dot is 14 units across in the globe's space: one ring fits, a
    // second extender collapses into a dashed ring in the first one's color,
    // and the whole glyph scales with the globe.
    @Test func theGlobeDotHoldsOneRing() {
        let unit = 0.65

        let direct = providerGlobeDotGeometry(row(extenders: []), unit: unit)
        #expect(direct.rings.isEmpty)
        #expect(abs(direct.dotDiameter - 14 * unit) < 1e-9)

        let one = providerGlobeDotGeometry(row(extenders: [Self.first]), unit: unit)
        #expect(one.rings.count == 1)
        #expect(one.rings.first?.dashed == false)
        #expect(one.rings.first?.colorHex == Self.first.colorHex)
        #expect(abs(one.dotDiameter - (14 - 2 * extenderRingStep) * unit) < 1e-9)
        #expect(abs(one.strokeWidth - extenderRingStrokeWidth * unit) < 1e-9)

        let migrating = providerGlobeDotGeometry(row(extenders: [Self.first, Self.second]), unit: unit)
        #expect(migrating.rings.count == 1)
        #expect(migrating.rings.first?.dashed == true)
        #expect(migrating.rings.first?.colorHex == Self.first.colorHex)
    }
}
