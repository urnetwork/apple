//
//  IpFamilyHistogramTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The histogram's grouping and sizing: which providers land in which row, in
 * what order, and how big a dot is relative to the connect widget.
 */
struct IpFamilyHistogramTests {

    private func point(_ id: String, _ family: String, state: String = "Added") -> IpFamilyHistogramPoint {
        IpFamilyHistogramPoint(id: id, state: state, ipFamily: family)
    }

    @Test func rowsAreAlwaysPresentInDisplayOrder() {
        let rows = ipFamilyHistogramRows([IpFamilyHistogramPoint]())
        #expect(rows.map { $0.family } == [.both, .v4, .v6])
        #expect(rows.allSatisfy { $0.pointIds.isEmpty })
    }

    @Test func groupsAddedProvidersByCategory() {
        let rows = ipFamilyHistogramRows([
            point("b", SdkIpFamilyDualstack),
            point("a", SdkIpFamilyDualstack),
            point("c", SdkIpFamilyV4Only),
            point("d", SdkIpFamilyV6Only),
        ])
        #expect(rows[0].pointIds == ["a", "b"])
        #expect(rows[1].pointIds == ["c"])
        #expect(rows[2].pointIds == ["d"])
    }

    // Only routing-eligible providers are dots: a provider still being
    // evaluated, one that failed, or one on its way out is not counted.
    @Test func countsOnlyAddedProviders() {
        let rows = ipFamilyHistogramRows([
            point("a", SdkIpFamilyDualstack, state: "InEvaluation"),
            point("b", SdkIpFamilyDualstack, state: "EvaluationFailed"),
            point("c", SdkIpFamilyV4Only, state: "NotAdded"),
            point("d", SdkIpFamilyV6Only, state: "Removed"),
            point("e", SdkIpFamilyV6Only, state: "Added"),
        ])
        #expect(rows[0].pointIds.isEmpty)
        #expect(rows[1].pointIds.isEmpty)
        #expect(rows[2].pointIds == ["e"])
    }

    // A legacy or unknown category carries v4, so it is a v4 dot rather than
    // a provider that vanishes from the histogram.
    @Test func legacyAndUnknownCategoriesReadAsV4() {
        let rows = ipFamilyHistogramRows([
            point("a", ""),
            point("b", "something-newer"),
        ])
        #expect(rows[1].pointIds == ["a", "b"])
    }

    @Test func rowsFromSdkGridPoints() {
        let id = SdkNewId()!
        let gridPoint = SdkProviderGridPoint()
        gridPoint.clientId = id
        gridPoint.state = "Added"
        gridPoint.ipFamily = SdkIpFamilyV6Only
        let rows = ipFamilyHistogramRows([id: gridPoint])
        #expect(rows[2].pointIds == [id.idStr])
    }

    // The dot is the widget's cell: the 256pt canvas over the grid width.
    @Test func dotSizeMatchesTheConnectWidgetCell() {
        #expect(ipFamilyHistogramDotSize(gridWidth: 16) == 16)
        #expect(ipFamilyHistogramDotSize(gridWidth: 32) == 8)
        #expect(ipFamilyHistogramDotSize(gridWidth: 10) == 25.6)
    }

    @Test func dotSizeFallsBackToTheDefaultGridBeforeTheGridHasAWidth() {
        #expect(ipFamilyHistogramDotSize(gridWidth: 0) == ipFamilyHistogramDotSize(gridWidth: ipFamilyHistogramDefaultGridWidth))
        #expect(ipFamilyHistogramDotSize(gridWidth: -1) == ipFamilyHistogramDotSize(gridWidth: 0))
    }
}
