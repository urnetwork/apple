//
//  WorldTopologyTests.swift
//  networkTests
//
//  Ported case-for-case from the android WorldTopologyTest.kt: the quantized
//  TopoJSON decode is verified against the same vendored world-110m.json.
//

import Foundation
import Testing
@testable import URnetwork

struct WorldTopologyTests {

    /// The bundled asset, or the checked-in source copy when the test runs
    /// without the host app's resources.
    private static let topology: WorldTopology? = {
        if let bundled = WorldTopology.loadFromBundle() {
            return bundled
        }
        // …/apple/app/networkTests/WorldTopologyTests.swift
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // networkTests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("network/Shared/Resources/world-110m.json")
        guard let data = try? Data(contentsOf: source) else {
            return nil
        }
        return try? WorldTopology.decode(data)
    }()

    private func requireTopology() throws -> WorldTopology {
        try #require(Self.topology, "world-110m.json resource not found")
    }

    @Test func decodesAll177Countries() throws {
        let world = try requireTopology()
        #expect(world.countries.count == 177)
        #expect(world.countries.allSatisfy { !$0.isoNumeric.isEmpty })
    }

    @Test func knownCountriesArePresent() throws {
        let world = try requireTopology()
        let ids = Set(world.countries.map { $0.isoNumeric })
        #expect(ids.contains("840"), "USA missing")
        #expect(ids.contains("036"), "Australia missing")
    }

    @Test func ringsAreWellFormedPolylines() throws {
        let world = try requireTopology()
        var ringCount = 0
        for country in world.countries {
            #expect(!country.rings.isEmpty)
            for ring in country.rings {
                ringCount += 1
                #expect(ring.count % 2 == 0, "odd float count")
                #expect(8 <= ring.count, "ring under 4 points")
            }
        }
        #expect(100 <= ringCount)
    }

    @Test func coordinatesAreWithinWorldBounds() throws {
        let world = try requireTopology()
        for country in world.countries {
            for ring in country.rings {
                for i in stride(from: 0, to: ring.count, by: 2) {
                    #expect(-180.0001 <= ring[i] && ring[i] <= 180.0001)
                    #expect(-90.0001 <= ring[i + 1] && ring[i + 1] <= 90.0001)
                }
            }
        }
    }

    @Test func everyRingCloses() throws {
        // TopoJSON polygon rings close: the first point of the first arc
        // equals the last point of the last arc; a stitching bug (dropped or
        // duplicated shared endpoints) breaks this
        let world = try requireTopology()
        for country in world.countries {
            for ring in country.rings {
                #expect(abs(ring[0] - ring[ring.count - 2]) <= 1e-3, "\(country.isoNumeric)")
                #expect(abs(ring[1] - ring[ring.count - 1]) <= 1e-3, "\(country.isoNumeric)")
            }
        }
    }

    @Test func totalPointCountIsInTheExpectedBand() throws {
        // world-110m decodes to ~10,500 ring points; far fewer means dropped
        // arcs, far more means shared endpoints were not deduplicated
        let world = try requireTopology()
        let totalPoints = world.countries.reduce(0) { sum, country in
            sum + country.rings.reduce(0) { $0 + $1.count / 2 }
        }
        #expect((5_000...60_000).contains(totalPoints), "total points \(totalPoints)")
    }

    @Test func dequantizesKnownUsaCoordinates() throws {
        // independently decoded (python): the first ring of the USA
        // MultiPolygon (Hawaii) has 17 points and starts at
        // (-155.541355, 19.084175)
        let world = try requireTopology()
        let usa = try #require(world.countries.first { $0.isoNumeric == "840" })
        let firstRing = try #require(usa.rings.first)
        #expect(firstRing.count == 17 * 2)
        #expect(abs(firstRing[0] - -155.541355) <= 5e-4)
        #expect(abs(firstRing[1] - 19.084175) <= 5e-4)
        #expect(abs(firstRing[0] - firstRing[firstRing.count - 2]) < 1e-3)
    }
}
