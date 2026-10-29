//
//  Top200TilePresentation.swift
//  URnetwork
//
//  What the Earnings Top 200 tile shows (apple/LEADERTOP.md §8, owner
//  decision 2026-10-29), from GET /sn/top/me, so it shows the same projected
//  position, margin and label as the Protocol leaderboard. Pure, so the
//  states are tested without a view.
//

import Foundation

struct Top200TilePresentation: Equatable {

    /// What the tile offers.
    enum Action: Equatable {
        /// binding is closed: the "Claiming opens soon" note, no claim
        /// button and no Sign fleet binding (Q16)
        case claimingSoon
        /// binding is open: the existing claim flow, Claim your spot and
        /// Sign fleet binding, with the warning
        case claim
        /// the network has claimed: its fleet, and Sign fleet binding while
        /// binding is open (bindings renew per epoch window)
        case claimed(signs: Bool)
    }

    let position: Int
    let label: SnTopLabel?
    let margin: Double
    /// the claimed fleet, as the Protocol board's detail sheet shows it
    let fleet: SnTopFleetInfo?
    let action: Action

    /**
     * The tile for a network that has claimed, or one the Protocol board
     * prompts to claim: measurable and projected inside the top 200. Any
     * other network has no tile; the Protocol tab shows where it ranks.
     */
    static func of(_ top: SnTopMeResultInfo?) -> Top200TilePresentation? {
        guard let top, let row = top.me.rankedRow else {
            return nil
        }
        let bindingOpen = top.snapshot.bindingOpen
        if let fleet = row.fleets.first {
            return Top200TilePresentation(
                position: row.position,
                label: row.label,
                margin: row.margin,
                fleet: fleet,
                action: .claimed(signs: bindingOpen)
            )
        }
        guard ProtocolClaimPrompt.of(row: row, bindingOpen: bindingOpen) != .hidden else {
            return nil
        }
        return Top200TilePresentation(
            position: row.position,
            label: row.label,
            margin: row.margin,
            fleet: nil,
            action: bindingOpen ? .claim : .claimingSoon
        )
    }

    /// "#1 of 142 claimed", when the validator's summary ranks the fleet
    var validatorRank: String? {
        guard let fleet, let rank = fleet.validatorRank else {
            return nil
        }
        if let of = fleet.validatorRankOf {
            return ProtocolText.detailValidatorRankValue(rank: rank, of: of)
        }
        return ProtocolFormat.rank(rank)
    }
}
