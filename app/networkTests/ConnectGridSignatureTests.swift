//
//  ConnectGridSignatureTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * What the connect grid's change signature covers.
 *
 * `updateGrid` skips the publish — and with it the canvas animation and every
 * drawer observer — when the signature is unchanged, so a field the ui draws
 * but the signature omits is a change nothing downstream ever sees.
 */
struct ConnectGridSignatureTests {

    private func point(
        _ id: String = "a",
        state: String = "Added",
        x: Int32 = 1,
        y: Int32 = 2,
        ipFamily: String = SdkIpFamilyV4Only,
        extenderIps: String = ""
    ) -> ConnectGridPointSignature {
        ConnectGridPointSignature(
            id: id,
            state: state,
            x: x,
            y: y,
            ipFamily: ipFamily,
            extenderIps: extenderIps
        )
    }

    private func signature(_ points: [ConnectGridPointSignature]) -> String {
        connectGridSignature(width: 16, windowCurrentSize: 8, points: points)
    }

    @Test func anUnchangedGridHasAnUnchangedSignature() {
        #expect(signature([point()]) == signature([point()]))
    }

    // IPV6.md D2: a provider proven on a second family moves histogram rows
    // without changing its state, position or membership
    @Test func aChangedIpFamilyChangesTheSignature() {
        #expect(
            signature([point(ipFamily: SdkIpFamilyV4Only)])
                != signature([point(ipFamily: SdkIpFamilyDualstack)])
        )
    }

    // EXTENDER.md K2: a transport migration changes only the extender ips,
    // and the dots' rings would otherwise never see it
    @Test func changedExtenderIpsChangeTheSignature() {
        #expect(
            signature([point(extenderIps: "")])
                != signature([point(extenderIps: "192.0.2.1")])
        )
        #expect(
            signature([point(extenderIps: "192.0.2.1")])
                != signature([point(extenderIps: "192.0.2.1,2001:db8::1")])
        )
    }

    @Test func stateAndPositionAndMembershipStillChangeTheSignature() {
        let base = signature([point()])
        #expect(signature([point(state: "Removed")]) != base)
        #expect(signature([point(x: 3)]) != base)
        #expect(signature([point(y: 3)]) != base)
        #expect(signature([point("b")]) != base)
        #expect(signature([point(), point("b")]) != base)
    }

    @Test func theGridShapeIsPartOfTheSignature() {
        #expect(
            connectGridSignature(width: 16, windowCurrentSize: 8, points: [point()])
                != connectGridSignature(width: 32, windowCurrentSize: 8, points: [point()])
        )
        #expect(
            connectGridSignature(width: 16, windowCurrentSize: 8, points: [point()])
                != connectGridSignature(width: 16, windowCurrentSize: 9, points: [point()])
        )
    }

    // the sdk re-emits the list in whatever order it likes; that is not a
    // change, and re-sorting it must not storm observers
    @Test func theListOrderIsNotAChange() {
        #expect(signature([point("a"), point("b")]) == signature([point("b"), point("a")]))
    }

    // the signature reads the sdk point, in the sdk's spelling
    @Test func thePointSignatureComesFromTheSdkGridPoint() {
        let gridPoint = SdkProviderGridPoint()
        gridPoint.state = "Added"
        gridPoint.x = 4
        gridPoint.y = 5
        gridPoint.ipFamily = SdkIpFamilyDualstack
        gridPoint.extenderIps = "192.0.2.1"
        #expect(
            ConnectGridPointSignature(id: "a", point: gridPoint)
                == point("a", state: "Added", x: 4, y: 5, ipFamily: SdkIpFamilyDualstack, extenderIps: "192.0.2.1")
        )
    }
}
