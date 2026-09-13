//
//  ExtenderPanelTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The extender panel's reading of the sdk status (EXTENDER.md K4, K5): which
 * extenders get a ring, which numbers the count prints, and what the gossip
 * state looks like.
 */
struct ExtenderPanelTests {

    private func extender(_ colorHex: String, inUse: Int) -> SdkExtenderInfo {
        let info = SdkExtenderInfo()
        info.colorHex = colorHex
        info.inUse = inUse
        return info
    }

    private func status(
        gossipState: String = SdkExtenderGossipStateConnected,
        activeCount: Int = 0,
        reserveCount: Int = 0,
        eventCountLastMinute: Int = 0,
        extenders: [SdkExtenderInfo] = []
    ) -> SdkExtenderStatus {
        let status = SdkExtenderStatus()
        status.gossipState = gossipState
        status.activeCount = activeCount
        status.reserveCount = reserveCount
        status.eventCountLastMinute = eventCountLastMinute
        let list = SdkNewExtenderInfoList()
        for extender in extenders {
            list?.add(extender)
        }
        status.extenders = list
        return status
    }

    // K4: one hollow ring per extender carrying at least one live connection
    // right now, in the sdk's order and the sdk's color
    @Test func ringsAreTheExtendersCarryingALiveConnection() {
        let model = ExtenderStatusModel(status(extenders: [
            extender("3cdd67", inUse: 2),
            extender("aaaaaa", inUse: 0),
            extender("dd4f3c", inUse: 1),
        ]))
        #expect(model.activeColorHexes == ["3cdd67", "dd4f3c"])
    }

    @Test func noExtendersInUseDrawsNoRings() {
        let model = ExtenderStatusModel(status(extenders: [extender("3cdd67", inUse: 0)]))
        #expect(model.activeColorHexes.isEmpty)
    }

    @Test func aStatusWithNoExtenderListIsEmpty() {
        let status = SdkExtenderStatus()
        status.extenders = nil
        #expect(ExtenderStatusModel(status).activeColorHexes.isEmpty)
    }

    // K4: "N of M" is the active addresses over every usable directory entry
    @Test func theCountIsActiveOverReserve() {
        let model = ExtenderStatusModel(status(activeCount: 2, reserveCount: 5))
        #expect(model.activeCount == 2)
        #expect(model.reserveCount == 5)
        // the format positions are pinned, not the wording: %1$lld is the
        // active count and %2$lld is the reserve, whatever a locale puts
        // between them
        let text = extenderPanelCountText(activeCount: 2, reserveCount: 5)
        let active = text.range(of: "2")
        let reserve = text.range(of: "5")
        #expect(active != nil)
        #expect(reserve != nil)
        if let active, let reserve {
            #expect(active.lowerBound < reserve.lowerBound)
        }
    }

    @Test func theEventRateIsTheTrailingMinutesApplies() {
        let model = ExtenderStatusModel(status(eventCountLastMinute: 17))
        #expect(model.eventCountLastMinute == 17)
        #expect(extenderEventRateText(17).contains("17"))
    }

    // K4: green connected, yellow connecting, red disconnected
    @Test func theGossipStateMapsToTheStatusDot() {
        #expect(ExtenderGossipDisplayState.of(gossipState: SdkExtenderGossipStateConnected) == .connected)
        #expect(ExtenderGossipDisplayState.of(gossipState: SdkExtenderGossipStateConnecting) == .connecting)
        #expect(ExtenderGossipDisplayState.of(gossipState: SdkExtenderGossipStateDisconnected) == .disconnected)
        #expect(ExtenderGossipDisplayState.connected.color == .urGreen)
        #expect(ExtenderGossipDisplayState.connecting.color == .urLightYellow)
        #expect(ExtenderGossipDisplayState.disconnected.color == .urCoral)
    }

    // a status that names no state is not a working one
    @Test func anUnknownGossipStateReadsAsDisconnected() {
        #expect(ExtenderGossipDisplayState.of(gossipState: "") == .disconnected)
        #expect(ExtenderGossipDisplayState.of(gossipState: "something-newer") == .disconnected)
        #expect(ExtenderStatusModel(status(gossipState: "")).gossipState == .disconnected)
    }

    @Test func everyStateHasItsOwnLabel() {
        // the three words the panel prints, one per state
        let labels = ExtenderGossipDisplayState.allCases.map { $0.label }
        #expect(labels.count == 3)
        #expect(Set(ExtenderGossipDisplayState.allCases.map { $0.rawValue }).count == 3)
    }

    @Test func theEmptyModelDrawsNothingAndReadsAsDisconnected() {
        #expect(ExtenderStatusModel.empty.activeColorHexes.isEmpty)
        #expect(ExtenderStatusModel.empty.activeCount == 0)
        #expect(ExtenderStatusModel.empty.reserveCount == 0)
        #expect(ExtenderStatusModel.empty.gossipState == .disconnected)
    }
}
