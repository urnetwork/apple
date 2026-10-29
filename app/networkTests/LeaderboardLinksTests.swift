//
//  LeaderboardLinksTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/**
 * The Protocol tab's place in the leaderboard (Q14) and the links between it
 * and Earnings (apple/LEADERTOP.md §5, §8): Claim on Earnings opens Account ›
 * Earnings at its Top 200 tile, and the tile's "See the Protocol
 * leaderboard" opens the leaderboard on its Protocol tab.
 */
@MainActor
struct LeaderboardLinksTests {

    @Test func protocolIsTheFirstTabAndTheDefault() {
        #expect(LeaderboardTab.allCases == [.protocol, .points, .data])
        #expect(LeaderboardTab.initial == .protocol)
    }

    @Test func claimOnEarningsOpensEarningsAndScrollsToTheTile() {
        let router = DeepLinkRouter()
        router.openEarningsTop200()
        #expect(router.pendingEarningsTop200)

        // the tab view takes it and shows the account tab
        #expect(router.consumeEarningsTop200())
        #expect(!router.pendingEarningsTop200)
        // the account tab opens Earnings
        #expect(router.consumeAccountPath() == .earnings)
        // and Earnings scrolls to its tile, once
        #expect(router.consumeEarningsTop200Scroll())
        #expect(!router.consumeEarningsTop200Scroll())
        // taken once
        #expect(!router.consumeEarningsTop200())
    }

    @Test func aScrollTheTileNeverShowedForIsDropped() {
        let router = DeepLinkRouter()
        router.openEarningsTop200()
        #expect(router.consumeEarningsTop200())
        router.cancelEarningsTop200Scroll()
        #expect(!router.pendingEarningsTop200Scroll)
        #expect(!router.consumeEarningsTop200Scroll())
    }

    @Test func seeTheBoardOpensTheLeaderboardOnItsProtocolTab() {
        let router = DeepLinkRouter()
        router.openProtocolLeaderboard()
        #expect(router.consumeProtocolLeaderboard())
        #expect(!router.pendingProtocolLeaderboard)
        // the leaderboard selects its Protocol tab, once
        #expect(router.consumeLeaderboardProtocol())
        #expect(!router.consumeLeaderboardProtocol())
        #expect(!router.consumeProtocolLeaderboard())
    }

    @Test func aLinkReturnsToAPageTheStackShowsInsteadOfPushingItAgain() {
        // Earnings with its Sign fleet binding open: back to Earnings
        #expect(AccountNavigationPaths.opening(.earnings, in: [.earnings, .top200Sign(nil)]) == [.earnings])
        #expect(AccountNavigationPaths.opening(.earnings, in: [.earnings]) == [.earnings])
        // anything else is pushed
        #expect(AccountNavigationPaths.opening(.earnings, in: []) == [.earnings])
        #expect(AccountNavigationPaths.opening(.earnings, in: [.settings]) == [.settings, .earnings])
        // a sign link with another binding is another page
        let link = Top200SignDestination(bindingText: "{}")
        #expect(AccountNavigationPaths.opening(.top200Sign(link), in: [.earnings, .top200Sign(nil)])
            == [.earnings, .top200Sign(nil), .top200Sign(link)])
    }
}
