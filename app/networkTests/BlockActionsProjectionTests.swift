import Foundation
import Testing
@testable import URnetwork

struct BlockActionsProjectionTests {
    private func row(_ id: String = "one", host: String = "same-site.test", bytes: Int64 = 10) -> BlockActionItem {
        BlockActionItem(
            id: id, time: Date(timeIntervalSince1970: 1),
            hosts: [host], ips: ["192.0.2.1"],
            matchedHosts: ["exact.test"], matchedIps: ["192.0.2.2"],
            hostBaseNames: [], block: false, local: false,
            overrideId: nil, hasBlockOverride: false, hasRouteOverride: false,
            packetCount: 1, byteCount: bytes, exitShortIds: []
        )
    }

    @Test func changedExitsRefreshOnlyTheLiveChips() {
        var projection = BlockActionsProjection()
        var calls = 0
        let initial = projection.refreshRows([row()], exitsByIp: [:]) { hosts in
            calls += 1
            return ["collapsed:\(hosts[0])"]
        }[0]
        for tick in 0..<12 {
            let next = projection.refreshExits([
                "192.0.2.1": ["exit-\(tick)", "shared"],
                "192.0.2.2": ["matched", "shared"],
            ])[0]
            #expect(next.exitShortIds == ["exit-\(tick)", "matched", "shared"])
            var withoutChangedChips = next
            withoutChangedChips.exitShortIds = initial.exitShortIds
            #expect(withoutChangedChips == initial)
        }
        #expect(calls == 1)
        #expect(projection.refreshExits([:])[0].exitShortIds.isEmpty)
    }

    @Test func namesAreMemoizedAcrossUnchangedAndByteOnlyEvents() {
        var projection = BlockActionsProjection()
        var calls = 0
        func collapse(_ hosts: [String]) -> [String] { calls += 1; return hosts }
        _ = projection.refreshRows([row()], exitsByIp: [:], collapseHosts: collapse)
        for bytes in 11...22 {
            let next = projection.refreshRows([row(bytes: Int64(bytes))], exitsByIp: [:], collapseHosts: collapse)
            #expect(next[0].byteCount == Int64(bytes))
        }
        #expect(calls == 1)
    }

    @Test func changedHostsRecomputeOnlyTheirRowAndReorderingKeepsIdentity() {
        var projection = BlockActionsProjection()
        var calls: [[String]] = []
        func collapse(_ hosts: [String]) -> [String] { calls.append(hosts); return hosts }
        _ = projection.refreshRows([row(), row("two", host: "other.test")], exitsByIp: [:], collapseHosts: collapse)
        let next = projection.refreshRows([row("two", host: "changed.test"), row()], exitsByIp: [:], collapseHosts: collapse)
        #expect(next.map(\.id) == ["two", "one"])
        #expect(next.map(\.hostBaseNames) == [["changed.test"], ["same-site.test"]])
        #expect(calls == [["same-site.test"], ["other.test"], ["changed.test"]])
    }

    @Test func removalAndDeviceResetDropTheMemo() {
        var projection = BlockActionsProjection()
        var calls = 0
        func collapse(_ hosts: [String]) -> [String] { calls += 1; return hosts }
        _ = projection.refreshRows([row()], exitsByIp: [:], collapseHosts: collapse)
        _ = projection.refreshRows([], exitsByIp: [:], collapseHosts: collapse)
        #expect(projection.refreshExits(["192.0.2.1": ["exit"]]).isEmpty)
        _ = projection.refreshRows([row()], exitsByIp: [:], collapseHosts: collapse)
        #expect(calls == 2)
        projection.clear()
        #expect(projection.rows.isEmpty)
        _ = projection.refreshRows([row()], exitsByIp: [:], collapseHosts: collapse)
        #expect(calls == 3)
    }

    @Test func updatedPolicyAndIpsAreNotMemoizedWithTheHosts() {
        var projection = BlockActionsProjection()
        var calls = 0
        func collapse(_ hosts: [String]) -> [String] { calls += 1; return hosts }
        _ = projection.refreshRows([row()], exitsByIp: [:], collapseHosts: collapse)
        let changed = BlockActionItem(
            id: "one", time: Date(timeIntervalSince1970: 2), hosts: ["same-site.test"],
            ips: ["192.0.2.3"], matchedHosts: [], matchedIps: [], hostBaseNames: [],
            block: true, local: true, overrideId: "rule", hasBlockOverride: true,
            hasRouteOverride: true, packetCount: 9, byteCount: 456, exitShortIds: []
        )
        let next = projection.refreshRows([changed], exitsByIp: ["192.0.2.1": ["old"], "192.0.2.3": ["new"]], collapseHosts: collapse)[0]
        var expected = changed
        expected.hostBaseNames = ["same-site.test"]
        expected.exitShortIds = ["new"]
        #expect(next == expected)
        #expect(calls == 1)
    }

    @Test func unchangedExitMapsPreservePublishedEquality() {
        var projection = BlockActionsProjection()
        let exits: [String: Set<String>] = ["192.0.2.1": ["one", "two"]]
        let initial = projection.refreshRows([row()], exitsByIp: exits) { $0 }
        for _ in 0..<12 { #expect(projection.refreshExits(exits) == initial) }
    }

    private func safetyRow(
        reason: String = "security-encrypted",
        safetyRule: Bool = true,
        routeLocalOverridable: Bool = true,
        block: Bool = true,
        local: Bool = false,
        overrideId: String? = nil,
        matchedHosts: [String] = []
    ) -> BlockActionItem {
        BlockActionItem(
            id: "safety", time: Date(timeIntervalSince1970: 1),
            hosts: [], ips: ["198.51.100.7"],
            matchedHosts: matchedHosts, matchedIps: [],
            hostBaseNames: [], block: block, local: local,
            overrideId: overrideId, hasBlockOverride: false, hasRouteOverride: overrideId != nil,
            packetCount: 1, byteCount: 10, exitShortIds: [],
            reason: reason, safetyRule: safetyRule, routeLocalOverridable: routeLocalOverridable
        )
    }

    @Test func safetyReasonSurvivesTheProjectionMemo() {
        var projection = BlockActionsProjection()
        _ = projection.refreshRows([safetyRow()], exitsByIp: [:]) { $0 }
        let next = projection.refreshRows([safetyRow()], exitsByIp: [:]) { $0 }[0]
        #expect(next.reason == "security-encrypted")
        #expect(next.safetyRule)
        #expect(next.routeLocalOverridable)
        #expect(projection.refreshExits(["198.51.100.7": ["exit"]])[0].safetyRule)
    }

    @Test func routeLocalIsOfferedOnlyForAnOverridableSafetyDropWithNoOverride() {
        #expect(safetyRow().offersRouteLocal)
        #expect(safetyRow(reason: "security-port").offersRouteLocal)
        // bittorrent and non-public destinations are never overridable
        #expect(!safetyRow(reason: "security-bittorrent", routeLocalOverridable: false).offersRouteLocal)
        #expect(!safetyRow(reason: "security-ip", routeLocalOverridable: false).offersRouteLocal)
        // the blocker is not a safety rule
        #expect(!safetyRow(reason: "blocker", safetyRule: false, routeLocalOverridable: false).offersRouteLocal)
        // kill switch off: already routed locally
        #expect(!safetyRow(block: false, local: true).offersRouteLocal)
        // an override already applies
        #expect(!safetyRow(overrideId: "rule").offersRouteLocal)
        #expect(!safetyRow(matchedHosts: ["exact.test"]).offersRouteLocal)
        // ordinary traffic carries no reason
        #expect(row().reason.isEmpty)
        #expect(!row().safetyRule)
        #expect(!row().offersRouteLocal)
    }
}
