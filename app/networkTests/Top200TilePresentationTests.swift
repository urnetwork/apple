//
//  Top200TilePresentationTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/**
 * The Earnings Top 200 tile reads GET /sn/top/me (apple/LEADERTOP.md §8):
 * which networks get it, what it offers while binding is closed and once it
 * opens, and a claimed network's fleet. The claimed detail sheet's facts are
 * here too, since the tile shows them as the sheet does.
 */
struct Top200TilePresentationTests {

    private static let enUS = Locale(identifier: "en_US")

    private static func top(
        position: Int,
        margin: Double = 0.12,
        label: SnTopLabel? = .estimate,
        measurable: Bool = true,
        bindingOpen: Bool = false,
        fleets: [SnTopFleetInfo] = []
    ) -> SnTopMeResultInfo {
        SnTopMeResultInfo(
            snapshot: SnTopSnapshotInfo(id: "s", bindingOpen: bindingOpen),
            me: SnTopMeInfo(row: SnTopRowInfo(
                position: position,
                margin: margin,
                label: label,
                measurable: measurable,
                claimPrompt: measurable && 1 <= position && position <= 200,
                isMe: true,
                fleets: fleets
            ))
        )
    }

    private static let fleet = SnTopFleetInfo(
        uid: 81,
        generation: 2,
        validToEpoch: 16,
        replicaScore: 312.4,
        validatorScore: 312.44,
        validatorRank: 1,
        validatorRankOf: 142,
        selected: true,
        incentive: 0.018,
        incentiveStale: true
    )

    @Test func whileBindingIsClosedTheTileSaysClaimingOpensSoon() {
        let tile = Top200TilePresentation.of(Self.top(position: 173, bindingOpen: false))
        #expect(tile?.action == .claimingSoon)
        #expect(tile?.position == 173)
        #expect(tile?.label == .estimate)
        #expect(tile?.margin == 0.12)
        #expect(tile?.fleet == nil)
    }

    @Test func whenBindingOpensTheExistingClaimFlowShows() {
        let tile = Top200TilePresentation.of(Self.top(position: 173, bindingOpen: true))
        #expect(tile?.action == .claim)
    }

    @Test func onlyAProjectedTop200NetworkGetsTheTile() {
        #expect(Top200TilePresentation.of(nil) == nil)
        // just outside the line
        #expect(Top200TilePresentation.of(Self.top(position: 201, margin: -0.01)) == nil)
        // inside but the validator cannot measure it
        #expect(Top200TilePresentation.of(Self.top(position: 150, label: .notMeasurable, measurable: false)) == nil)
        // not ranked
        #expect(Top200TilePresentation.of(Self.top(position: 0)) == nil)
        let unranked = SnTopMeResultInfo(snapshot: SnTopSnapshotInfo(id: "s"), me: SnTopMeInfo(row: nil))
        #expect(Top200TilePresentation.of(unranked) == nil)
    }

    @Test func aClaimedNetworkSeesItsFleetAndSignsOnlyWhileBindingIsOpen() {
        let open = Top200TilePresentation.of(Self.top(position: 1, bindingOpen: true, fleets: [Self.fleet]))
        #expect(open?.action == .claimed(signs: true))
        #expect(open?.fleet == Self.fleet)
        #expect(open?.validatorRank == "#1 of 142 claimed")
        let closed = Top200TilePresentation.of(Self.top(position: 1, bindingOpen: false, fleets: [Self.fleet]))
        #expect(closed?.action == .claimed(signs: false))
        // a claimed network keeps its tile outside the line, where it earns nothing
        let below = Top200TilePresentation.of(Self.top(position: 260, margin: -0.3, label: .unlikely, bindingOpen: true, fleets: [Self.fleet]))
        #expect(below?.action == .claimed(signs: true))
    }

    @Test func aFleetTheValidatorHasNotRankedHasNoRankLine() {
        let unranked = SnTopFleetInfo(uid: 77)
        let tile = Top200TilePresentation.of(Self.top(position: 202, bindingOpen: true, fleets: [unranked]))
        #expect(tile?.validatorRank == nil)
    }

    // MARK: the claimed detail sheet

    @Test func theSheetListsWhatIsKnownInOrder() {
        let row = SnTopRowInfo(position: 1, fleets: [Self.fleet])
        let facts = ProtocolClaimedDetail.facts(row: row, fleet: Self.fleet, locale: Self.enUS)
        #expect(facts.map(\.label) == [
            "Projected rank",
            "Validator rank",
            "Validator score",
            "Board replica score",
            "On-chain incentive",
            "Generation",
            "Claim valid until",
        ])
        #expect(facts.map(\.value) == [
            "#1",
            "#1 of 142 claimed",
            "312.4",
            "312.4",
            "1.8% · stale",
            "2",
            "Epoch 16",
        ])
    }

    @Test func theSheetLeavesOutWhatTheValidatorAndChainHaveNotSaid() {
        let bare = SnTopFleetInfo(uid: 77, generation: 1, validToEpoch: 9, replicaScore: 40.7)
        let row = SnTopRowInfo(position: 202, fleets: [bare])
        let facts = ProtocolClaimedDetail.facts(row: row, fleet: bare, locale: Self.enUS)
        #expect(facts.map(\.label) == ["Projected rank", "Board replica score", "Generation", "Claim valid until"])
        #expect(ProtocolClaimedDetail.selection(bare) == nil)
    }

    @Test func selectionReadsSelectedOrNot() {
        #expect(ProtocolClaimedDetail.selection(Self.fleet) == "Selected")
        var notSelected = Self.fleet
        notSelected.selected = false
        #expect(ProtocolClaimedDetail.selection(notSelected) == "Not selected")
    }

    @Test func incentiveIsAPercentOfTheSubnets() {
        #expect(ProtocolClaimedDetail.incentivePercent(0.018, locale: Self.enUS) == "1.8%")
        #expect(ProtocolClaimedDetail.incentivePercent(0, locale: Self.enUS) == "0.0%")
    }
}
