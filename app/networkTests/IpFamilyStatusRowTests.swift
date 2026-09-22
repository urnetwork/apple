//
//  IpFamilyStatusRowTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The status row's counting, ranking and line selection: which providers
 * count in which column, which column is bright, and which lines a column
 * shows.
 */
struct IpFamilyStatusRowTests {

    private func point(_ family: String, state: String = "Added") -> IpFamilyStatusPoint {
        IpFamilyStatusPoint(state: state, ipFamily: family)
    }

    private func status(
        _ column: IpFamilyColumn,
        connected: Int = 0,
        connecting: Int = 0
    ) -> IpFamilyColumnStatus {
        IpFamilyColumnStatus(column: column, connectedCount: connected, connectingCount: connecting)
    }

    // MARK: counting

    @Test func columnsAreAlwaysPresentInDisplayOrder() {
        let statuses = ipFamilyColumnStatuses([IpFamilyStatusPoint]())
        #expect(statuses.map { $0.column } == [.dualstack, .v4, .v6])
        #expect(statuses.allSatisfy { $0.isUnavailable })
    }

    // The columns are categories, not capabilities: a dualstack provider
    // counts once, under Dualstack, never under IPv4 or IPv6 as well.
    @Test func countsConnectedAndConnectingByCategory() {
        let statuses = ipFamilyColumnStatuses([
            point(SdkIpFamilyDualstack),
            point(SdkIpFamilyDualstack),
            point(SdkIpFamilyDualstack, state: "InEvaluation"),
            point(SdkIpFamilyV4Only),
            point(SdkIpFamilyV6Only, state: "InEvaluation"),
            point(SdkIpFamilyV6Only, state: "InEvaluation"),
        ])
        #expect(statuses[0] == status(.dualstack, connected: 2, connecting: 1))
        #expect(statuses[1] == status(.v4, connected: 1))
        #expect(statuses[2] == status(.v6, connecting: 2))
    }

    // A provider that failed evaluation, was not added, or is on its way out
    // (it lingers on the grid for the removal tween) counts as nothing.
    @Test func ignoresProvidersThatAreNotLive() {
        let statuses = ipFamilyColumnStatuses([
            point(SdkIpFamilyDualstack, state: "EvaluationFailed"),
            point(SdkIpFamilyV4Only, state: "NotAdded"),
            point(SdkIpFamilyV6Only, state: "Removed"),
            point(SdkIpFamilyV6Only, state: "something-newer"),
        ])
        #expect(statuses.allSatisfy { $0.isUnavailable })
    }

    // A legacy or unknown category carries v4, so it is an IPv4 provider
    // rather than one that vanishes from the row.
    @Test func legacyAndUnknownCategoriesReadAsV4() {
        let statuses = ipFamilyColumnStatuses([
            point(""),
            point("something-newer", state: "InEvaluation"),
        ])
        #expect(statuses[1] == status(.v4, connected: 1, connecting: 1))
    }

    @Test func statusesFromSdkGridPoints() {
        let added = SdkNewId()!
        let addedPoint = SdkProviderGridPoint()
        addedPoint.clientId = added
        addedPoint.state = "Added"
        addedPoint.ipFamily = SdkIpFamilyV6Only

        let evaluating = SdkNewId()!
        let evaluatingPoint = SdkProviderGridPoint()
        evaluatingPoint.clientId = evaluating
        evaluatingPoint.state = "InEvaluation"
        evaluatingPoint.ipFamily = SdkIpFamilyDualstack

        let statuses = ipFamilyColumnStatuses([added: addedPoint, evaluating: evaluatingPoint])
        #expect(statuses[0] == status(.dualstack, connecting: 1))
        #expect(statuses[2] == status(.v6, connected: 1))
    }

    // MARK: ranking

    @Test func dualstackConnectedIsBestAndTheOthersAreDimmed() {
        let tiers = ipFamilyColumnTiers([
            status(.dualstack, connected: 1),
            status(.v4, connected: 3),
            status(.v6, connecting: 1),
        ])
        #expect(tiers[.dualstack] == .best)
        #expect(tiers[.v4] == .active)
        #expect(tiers[.v6] == .active)
    }

    // IPv4 and IPv6 tie, so with nothing dualstack connected they share the
    // top.
    @Test func v4AndV6ShareBestWhenNothingDualstackIsConnected() {
        let tiers = ipFamilyColumnTiers([
            status(.dualstack),
            status(.v4, connected: 2),
            status(.v6, connected: 1),
        ])
        #expect(tiers[.dualstack] == .unavailable)
        #expect(tiers[.v4] == .best)
        #expect(tiers[.v6] == .best)
    }

    @Test func aLoneConnectedColumnIsBest() {
        let tiers = ipFamilyColumnTiers([
            status(.dualstack),
            status(.v4),
            status(.v6, connected: 1),
        ])
        #expect(tiers[.dualstack] == .unavailable)
        #expect(tiers[.v4] == .unavailable)
        #expect(tiers[.v6] == .best)
    }

    // A column that is only connecting carries no traffic yet: it is active,
    // never best, even when it outranks the connected column.
    @Test func aConnectingOnlyColumnIsActiveNotBest() {
        let tiers = ipFamilyColumnTiers([
            status(.dualstack, connecting: 2),
            status(.v4, connected: 1),
            status(.v6),
        ])
        #expect(tiers[.dualstack] == .active)
        #expect(tiers[.v4] == .best)
        #expect(tiers[.v6] == .unavailable)
    }

    @Test func onlyConnectingColumnsMakeNothingBest() {
        let tiers = ipFamilyColumnTiers([
            status(.dualstack, connecting: 1),
            status(.v4, connecting: 1),
            status(.v6),
        ])
        #expect(tiers[.dualstack] == .active)
        #expect(tiers[.v4] == .active)
        #expect(tiers[.v6] == .unavailable)
    }

    @Test func nothingLiveMakesEveryColumnUnavailable() {
        let tiers = ipFamilyColumnTiers(ipFamilyColumnStatuses([IpFamilyStatusPoint]()))
        #expect(tiers.values.allSatisfy { $0 == .unavailable })
        #expect(tiers.count == 3)
    }

    // MARK: lines

    @Test func linesShowTheNonZeroCountsConnectedFirst() {
        #expect(ipFamilyStatusLines(status(.v4, connected: 3, connecting: 1)) == [.connected(3), .connecting(1)])
        #expect(ipFamilyStatusLines(status(.v4, connected: 3)) == [.connected(3)])
        #expect(ipFamilyStatusLines(status(.v4, connecting: 1)) == [.connecting(1)])
    }

    @Test func aColumnWithNothingReadsDisconnected() {
        #expect(ipFamilyStatusLines(status(.v6)) == [.disconnected])
    }

    // The line id is its kind, so a count change is an in-place update (the
    // number rolls) while a kind change is an insertion or removal (the line
    // fades).
    @Test func lineIdentityIsTheKind() {
        #expect(IpFamilyStatusLine.connected(1).id == IpFamilyStatusLine.connected(2).id)
        #expect(IpFamilyStatusLine.connected(1).id != IpFamilyStatusLine.connecting(1).id)
        #expect(IpFamilyStatusLine.connected(1) != IpFamilyStatusLine.connected(2))
    }
}
