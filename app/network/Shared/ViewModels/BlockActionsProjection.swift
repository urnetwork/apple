import Foundation

/** A recent routing decision, aggregated per destination cluster. */
struct BlockActionItem: Identifiable, Equatable {
    let id: String
    let time: Date
    // Unmatched hosts/ips are disjoint from the matched sets.
    let hosts: [String]
    let ips: [String]
    let matchedHosts: [String]
    let matchedIps: [String]
    // Derived display values can refresh without reading the SDK action again.
    var hostBaseNames: [String]
    let block: Bool
    let local: Bool
    let overrideId: String?
    let hasBlockOverride: Bool
    let hasRouteOverride: Bool
    let packetCount: Int
    let byteCount: Int64
    // The live exit join, not the exit at the time of the routing decision.
    var exitShortIds: [String]

    var allHostNames: [String] { matchedHosts + hosts }
    var allIps: [String] { matchedIps + ips }
    var hostValues: [String] { allHostNames + allIps }
    var ipCount: Int { ips.count }
}

/** Value-only UI projection; its memo contains only currently displayed rows. */
struct BlockActionsProjection {
    private(set) var rows: [BlockActionItem] = []

    mutating func clear() {
        rows = []
    }

    mutating func refreshRows(
        _ source: [BlockActionItem],
        exitsByIp: [String: Set<String>],
        collapseHosts: ([String]) -> [String]
    ) -> [BlockActionItem] {
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        rows = source.map { row in
            var projected = row
            if let old = previous[row.id], old.hosts == row.hosts {
                projected.hostBaseNames = old.hostBaseNames
            } else {
                projected.hostBaseNames = collapseHosts(row.hosts)
            }
            projected.exitShortIds = Self.exitIds(row, exitsByIp: exitsByIp)
            return projected
        }
        return rows
    }

    mutating func refreshExits(_ exitsByIp: [String: Set<String>]) -> [BlockActionItem] {
        for index in rows.indices {
            let ids = Self.exitIds(rows[index], exitsByIp: exitsByIp)
            if ids != rows[index].exitShortIds {
                rows[index].exitShortIds = ids
            }
        }
        return rows
    }

    private static func exitIds(_ row: BlockActionItem, exitsByIp: [String: Set<String>]) -> [String] {
        var ids = Set<String>()
        for ip in row.matchedIps { ids.formUnion(exitsByIp[ip] ?? []) }
        for ip in row.ips { ids.formUnion(exitsByIp[ip] ?? []) }
        return ids.sorted()
    }
}
