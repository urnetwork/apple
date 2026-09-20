import Foundation
import Testing
@testable import URnetwork

/** Optional pure-host benchmark. It deliberately excludes Objective-C/Go bridge cost. */
struct BlockActionsProjectionBenchmark {
    @Test func projectionOnly() {
        guard ProcessInfo.processInfo.environment["URNETWORK_PROJECTION_BENCHMARK"] == "1" else { return }
        let input = (0..<200).map { index in
            BlockActionItem(
                id: "row-\(index)", time: Date(timeIntervalSince1970: 1),
                hosts: ["same-site.test"], ips: ["192.0.2.1"],
                matchedHosts: [], matchedIps: ["192.0.2.2"], hostBaseNames: [],
                block: false, local: false, overrideId: nil, hasBlockOverride: false,
                hasRouteOverride: false, packetCount: 1, byteCount: 10, exitShortIds: []
            )
        }
        var calls = 0
        let names = ["*.same-site.test"]
        func collapse(_ hosts: [String]) -> [String] { calls += 1; return names }
        var projection = BlockActionsProjection()
        _ = projection.refreshRows(input, exitsByIp: [:], collapseHosts: collapse)
        let iterations = 2_000
        var sink: [BlockActionItem] = []
        func legacy(_ exits: [String: Set<String>]) -> [BlockActionItem] {
            input.map { row in
                var next = row
                next.hostBaseNames = collapse(row.hosts)
                var ids = Set<String>()
                for ip in row.matchedIps + row.ips { ids.formUnion(exits[ip] ?? []) }
                next.exitShortIds = ids.sorted()
                return next
            }
        }
        func exits(_ iteration: Int) -> [String: Set<String>] {
            ["192.0.2.1": [iteration % 2 == 0 ? "one" : "other"], "192.0.2.2": ["two"]]
        }
        for index in 0..<500 {
            sink = legacy(exits(index))
            sink = projection.refreshExits(exits(index))
        }
        for rep in 1...6 {
            for arm in rep % 2 == 1 ? ["legacy", "candidate"] : ["candidate", "legacy"] {
                let beforeCalls = calls
                let start = DispatchTime.now().uptimeNanoseconds
                for index in 0..<iterations {
                    let current = exits(index)
                    sink = arm == "legacy" ? legacy(current) : projection.refreshExits(current)
                }
                let duration = DispatchTime.now().uptimeNanoseconds - start
                let collapseCalls = calls - beforeCalls
                #expect(collapseCalls == (arm == "legacy" ? iterations * input.count : 0))
                #expect(sink.count == input.count)
                #expect(sink[0].exitShortIds == ["other", "two"])
                print("{\"arm\":\"\(arm)\",\"rep\":\(rep),\"rows\":200,\"nsPerTick\":\(Double(duration) / Double(iterations)),\"collapseCalls\":\(collapseCalls)}")
            }
        }
    }
}
