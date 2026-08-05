//
//  WorldTopology.swift
//  URnetwork
//
//  Quantized-TopoJSON decoder for the provider-locations globe's land
//  outlines. Pure value math with no SwiftUI dependency, unit tested directly
//  (WorldTopologyTests) — a port of the Android WorldTopology.kt.
//

import Foundation

/**
 * One country from the world topology: its ISO-3166-1 numeric id (zero
 * padded, e.g. "840" is the USA) and its outline rings in lon/lat degrees.
 * Each ring is a packed array of [lon0, lat0, lon1, lat1, ...] and is closed
 * (first point equals last point). MultiPolygon countries contribute all of
 * their rings, flattened.
 */
struct CountryShape {
    let isoNumeric: String
    let rings: [[Double]]
}

/**
 * The world map decoded from quantized TopoJSON (world-110m.json in the app
 * bundle). Only `objects.countries` is decoded; `land` and `bbox` are ignored.
 *
 * TopoJSON stores shared borders once as delta-encoded quantized integer
 * arcs; polygons reference arcs by index, with a negative index i meaning
 * arc ~i traversed in reverse. See https://github.com/topojson/topojson.
 */
struct WorldTopology {

    let countries: [CountryShape]

    enum DecodeError: Error {
        case malformed(String)
    }

    static let bundleResourceName = "world-110m"

    /**
     * Decodes the topology shipped in the app bundle. Returns nil when the
     * resource is missing or unreadable — the globe still draws its sphere,
     * graticule and provider dots without land.
     */
    static func loadFromBundle(_ bundle: Bundle = .main) -> WorldTopology? {
        guard let url = bundle.url(forResource: bundleResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decode(data)
    }

    static func decode(_ data: Data) throws -> WorldTopology {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.malformed("root is not an object")
        }
        guard let transform = root["transform"] as? [String: Any],
              let scale = transform["scale"] as? [Double],
              let translate = transform["translate"] as? [Double],
              2 <= scale.count, 2 <= translate.count else {
            throw DecodeError.malformed("missing quantization transform")
        }
        let scaleX = scale[0]
        let scaleY = scale[1]
        let translateX = translate[0]
        let translateY = translate[1]

        // Decode every arc once. Each arc is a list of [x, y] integer points
        // where the first point is absolute (quantized) and every later point
        // is a delta; the running sums dequantize to degrees as
        // lon = x * scale[0] + translate[0], lat = y * scale[1] + translate[1].
        // Packed as [lon0, lat0, lon1, lat1, ...].
        guard let arcsJson = root["arcs"] as? [[[NSNumber]]] else {
            throw DecodeError.malformed("missing arcs")
        }
        let arcs: [[Double]] = arcsJson.map { arc in
            var points = [Double](repeating: 0, count: arc.count * 2)
            var x = 0
            var y = 0
            for j in arc.indices {
                let point = arc[j]
                guard 2 <= point.count else {
                    continue
                }
                x += point[0].intValue
                y += point[1].intValue
                points[2 * j] = Double(x) * scaleX + translateX
                points[2 * j + 1] = Double(y) * scaleY + translateY
            }
            return points
        }

        guard let objects = root["objects"] as? [String: Any],
              let countriesObject = objects["countries"] as? [String: Any],
              let geometries = countriesObject["geometries"] as? [[String: Any]] else {
            throw DecodeError.malformed("missing objects.countries.geometries")
        }

        var countries: [CountryShape] = []
        countries.reserveCapacity(geometries.count)
        for geometry in geometries {
            let id = Self.identifier(geometry["id"])
            guard let type = geometry["type"] as? String else {
                throw DecodeError.malformed("geometry without a type")
            }
            let rings: [[Double]]
            switch type {
            case "Polygon":
                // a Polygon is a list of rings, each a list of arc indexes
                guard let polygon = geometry["arcs"] as? [[NSNumber]] else {
                    throw DecodeError.malformed("malformed Polygon arcs")
                }
                rings = try polygon.map { try stitchRing(arcIndexes: $0, arcs: arcs) }
            case "MultiPolygon":
                // a MultiPolygon is a list of polygons
                guard let multiPolygon = geometry["arcs"] as? [[[NSNumber]]] else {
                    throw DecodeError.malformed("malformed MultiPolygon arcs")
                }
                rings = try multiPolygon.flatMap { polygon in
                    try polygon.map { try stitchRing(arcIndexes: $0, arcs: arcs) }
                }
            default:
                throw DecodeError.malformed("unsupported geometry type \(type)")
            }
            countries.append(CountryShape(isoNumeric: id, rings: rings))
        }
        return WorldTopology(countries: countries)
    }

    /// TopoJSON ids are strings here (zero padded, "036"), but the spec allows
    /// numbers; accept either so a re-vendored asset cannot silently lose ids.
    private static func identifier(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    /**
     * Concatenates the referenced arcs into one closed ring. A negative index
     * i references arc ~i reversed. After orientation, each arc's first point
     * equals the previous arc's last point, so the duplicate is dropped when
     * stitching.
     */
    private static func stitchRing(arcIndexes: [NSNumber], arcs: [[Double]]) throws -> [Double] {
        var pointCount = 0
        for element in arcIndexes {
            let index = element.intValue
            let resolved = 0 <= index ? index : ~index
            guard arcs.indices.contains(resolved) else {
                throw DecodeError.malformed("arc index \(index) out of range")
            }
            pointCount += arcs[resolved].count / 2
        }
        pointCount -= arcIndexes.count - 1
        guard 0 < pointCount else {
            throw DecodeError.malformed("empty ring")
        }
        var ring = [Double](repeating: 0, count: pointCount * 2)
        var write = 0
        for k in arcIndexes.indices {
            let index = arcIndexes[k].intValue
            let skipSharedEndpoint = 0 < k
            if 0 <= index {
                let arc = arcs[index]
                let from = skipSharedEndpoint ? 1 : 0
                for p in from..<(arc.count / 2) {
                    ring[write] = arc[2 * p]
                    ring[write + 1] = arc[2 * p + 1]
                    write += 2
                }
            } else {
                let arc = arcs[~index]
                let last = arc.count / 2 - 1
                let from = skipSharedEndpoint ? last - 1 : last
                var p = from
                while 0 <= p {
                    ring[write] = arc[2 * p]
                    ring[write + 1] = arc[2 * p + 1]
                    write += 2
                    p -= 1
                }
            }
        }
        return ring
    }
}
