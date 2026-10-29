//
//  ProtocolTopPresentationTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/**
 * What the Protocol leaderboard says (apple/LEADERTOP.md): the numbers, the
 * banners, the claim prompt's states, how networks are named (Q12), the 200
 * line, what VoiceOver reads for a row, the progress chart's points, and the
 * paging rules. Pure values; no device, no sdk.
 */
struct ProtocolTopPresentationTests {

    private static let enUS = Locale(identifier: "en_US")

    private static func row(
        _ position: Int,
        name: String = "",
        margin: Double = 0,
        trend: Int = 0,
        label: SnTopLabel? = .estimate,
        measurable: Bool = true,
        claimPrompt: Bool? = nil,
        isMe: Bool = false,
        fleets: [SnTopFleetInfo] = []
    ) -> SnTopRowInfo {
        SnTopRowInfo(
            position: position,
            name: name,
            projectedScore: 41.24,
            margin: margin,
            trend: trend,
            label: label,
            measurable: measurable,
            claimPrompt: claimPrompt ?? (measurable && position <= 200),
            isMe: isMe,
            fleets: fleets
        )
    }

    // MARK: numbers

    @Test func scoresShowOneDecimal() {
        #expect(ProtocolFormat.score(41.24, locale: Self.enUS) == "41.2")
        #expect(ProtocolFormat.score(312, locale: Self.enUS) == "312.0")
        #expect(ProtocolFormat.score(1234.56, locale: Self.enUS) == "1,234.6")
    }

    @Test func marginsShowWholePercentsAndOneDecimalUnderOne() {
        #expect(ProtocolFormat.percent(0.12, locale: Self.enUS) == "12%")
        // the size only: the sentence says above or below
        #expect(ProtocolFormat.percent(-0.08, locale: Self.enUS) == "8%")
        // just over the line never reads "0%"
        #expect(ProtocolFormat.percent(0.004, locale: Self.enUS) == "0.4%")
        #expect(ProtocolFormat.percent(0, locale: Self.enUS) == "0%")
    }

    @Test func countsAndRanksGroupTheirDigits() {
        #expect(ProtocolFormat.count(41_230, locale: Self.enUS) == "41,230")
        #expect(ProtocolFormat.rank(173, locale: Self.enUS) == "#173")
        #expect(ProtocolFormat.rank(1_240, locale: Self.enUS) == "#1,240")
    }

    @Test func theMarginSaysAboveOrBelowTheLine() {
        #expect(ProtocolText.margin(0.12, locale: Self.enUS) == "12% above the Top 200 line")
        #expect(ProtocolText.margin(-0.08, locale: Self.enUS) == "8% below the Top 200 line")
        // the 200th network is on the line: inside
        #expect(ProtocolText.margin(0, locale: Self.enUS) == "0% above the Top 200 line")
    }

    @Test func theEarningsTileSignsItsMargin() {
        #expect(ProtocolFormat.signedPercent(0.12, locale: Self.enUS) == "+12%")
        #expect(ProtocolFormat.signedPercent(-0.08, locale: Self.enUS) == "\u{2212}8%")
        #expect(ProtocolText.earningsProjected(margin: 0.12, locale: Self.enUS) == "projected · +12%")
        #expect(ProtocolText.earningsProjected(margin: -0.08, locale: Self.enUS) == "projected · \u{2212}8%")
    }

    @Test func whyThisScoreCountsThePrefixes() {
        #expect(ProtocolText.why(prefixes: 18, shared: 3) == "Distinct IP prefixes: 18. Shared with other networks: 3.")
        #expect(ProtocolText.why(prefixes: 1, shared: 0) == "Distinct IP prefixes: 1. Shared with other networks: 0.")
    }

    @Test func theTrendIsUpDownOrNothing() {
        #expect(ProtocolText.trend(9) == "up 9 since the last update")
        #expect(ProtocolText.trend(-2) == "down 2 since the last update")
        #expect(ProtocolText.trend(0) == nil)
    }

    @Test func theLineReadsItsScore() {
        #expect(ProtocolText.line(cutoff: 41.24, locale: Self.enUS) == "Top 200 line · score 41.2")
        #expect(ProtocolText.lineAccessibility(cutoff: 41.24, locale: Self.enUS) == "Top 200 line, score 41.2")
    }

    @Test func theStaleBannerSaysHowLongAgo() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let text = ProtocolText.bannerStale(computedAt: now.addingTimeInterval(-4 * 3600), now: now, locale: Self.enUS)
        #expect(text == "Rankings last updated 4 hours ago.")
    }

    // MARK: banners

    @Test func bindingClosedShowsTheNeutralBanner() {
        let closed = SnTopSnapshotInfo(id: "s", bindingOpen: false)
        #expect(ProtocolBanner.of(closed) == [.bindingClosed])
        // when binding opens, the banner goes
        let open = SnTopSnapshotInfo(id: "s", bindingOpen: true)
        #expect(ProtocolBanner.of(open).isEmpty)
        // nothing before a snapshot has loaded
        #expect(ProtocolBanner.of(nil).isEmpty)
    }

    @Test func aStaleSnapshotSaysWhenItWasComputed() {
        let computedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let stale = SnTopSnapshotInfo(id: "s", computedAt: computedAt, bindingOpen: true, stale: true)
        #expect(ProtocolBanner.of(stale) == [.stale(computedAt: computedAt)])
        let both = SnTopSnapshotInfo(id: "s", computedAt: computedAt, bindingOpen: false, stale: true)
        #expect(ProtocolBanner.of(both) == [.bindingClosed, .stale(computedAt: computedAt)])
        // stale without a time it could say: no banner rather than a wrong one
        let unknown = SnTopSnapshotInfo(id: "s", bindingOpen: true, stale: true)
        #expect(ProtocolBanner.of(unknown).isEmpty)
    }

    // MARK: the claim prompt

    @Test func theClaimPromptFollowsBinding() {
        let inside = Self.row(173, margin: 0.25)
        #expect(ProtocolClaimPrompt.of(row: inside, bindingOpen: true) == .claim(close: false))
        #expect(ProtocolClaimPrompt.of(row: inside, bindingOpen: false) == .soon(close: false))
    }

    @Test func onlyAMeasurableNetworkInsideTheTop200IsPrompted() {
        #expect(ProtocolClaimPrompt.of(row: nil, bindingOpen: true) == .hidden)
        #expect(ProtocolClaimPrompt.of(row: Self.row(201, margin: -0.01), bindingOpen: true) == .hidden)
        #expect(ProtocolClaimPrompt.of(row: Self.row(150, label: .notMeasurable, measurable: false), bindingOpen: true) == .hidden)
        // the server's flag decides as well
        #expect(ProtocolClaimPrompt.of(row: Self.row(150, claimPrompt: false), bindingOpen: true) == .hidden)
        // an unranked network
        #expect(ProtocolClaimPrompt.of(row: Self.row(0, claimPrompt: true), bindingOpen: true) == .hidden)
    }

    @Test func aNetworkThatClaimedIsNotAskedToClaim() {
        let claimed = Self.row(12, margin: 0.9, fleets: [SnTopFleetInfo(uid: 81)])
        #expect(ProtocolClaimPrompt.of(row: claimed, bindingOpen: true) == .hidden)
    }

    @Test func closeToTheLineAddsItsWarning() {
        // the label says borderline
        #expect(ProtocolClaimPrompt.of(row: Self.row(196, margin: 0.03, label: .borderline), bindingOpen: true) == .claim(close: true))
        // while every row is an estimate, the margin decides (Q17)
        #expect(ProtocolClaimPrompt.of(row: Self.row(196, margin: 0.03, label: .estimate), bindingOpen: false) == .soon(close: true))
        #expect(ProtocolClaimPrompt.of(row: Self.row(150, margin: 0.2, label: .estimate), bindingOpen: false) == .soon(close: false))
        // likely is inside by at least 20%
        #expect(ProtocolClaimPrompt.of(row: Self.row(100, margin: 0.1, label: .likely), bindingOpen: true) == .claim(close: false))
    }

    // MARK: names

    @Test func rowsShowANameOnlyWhenTheNetworkOptedIn() {
        #expect(ProtocolName.of(Self.row(1, name: "kayak-hollow")) == .name("kayak-hollow"))
        #expect(ProtocolName.of(Self.row(2)) == .anonymous)
        #expect(ProtocolName.of(Self.row(2, name: "  ")) == .anonymous)
        #expect(ProtocolName.of(Self.row(2)).text == "Anonymous")
    }

    @Test func anAnonymousClaimedNetworkShowsItsUids() {
        let claimed = Self.row(202, fleets: [SnTopFleetInfo(uid: 77)])
        #expect(ProtocolName.of(claimed) == .uids([77]))
        #expect(ProtocolName.of(claimed).text == "UID 77")
        let two = Self.row(9, fleets: [SnTopFleetInfo(uid: 81), SnTopFleetInfo(uid: 90)])
        #expect(ProtocolName.of(two).text == "UID 81, UID 90")
        // a named claimed network keeps its name
        #expect(ProtocolName.of(Self.row(196, name: "quiet-harbor", fleets: [SnTopFleetInfo(uid: 212)])) == .name("quiet-harbor"))
    }

    @Test func theCardShowsTheNameOnlyWhileTheSwitchIsOn() {
        #expect(ProtocolName.own(isPublic: false, rowName: "kayak-hollow", sessionName: "kayak-hollow") == .anonymous)
        #expect(ProtocolName.own(isPublic: true, rowName: "kayak-hollow", sessionName: "other") == .name("kayak-hollow"))
        // the row trails a switch just turned on: the session's name stands in
        #expect(ProtocolName.own(isPublic: true, rowName: "", sessionName: "kayak-hollow") == .name("kayak-hollow"))
        #expect(ProtocolName.own(isPublic: true, rowName: "", sessionName: "") == .anonymous)
    }

    // MARK: the 200 line

    @Test func theLineFollowsRow200AndTintsTheRowsAboveIt() {
        #expect(ProtocolLine.follows(200))
        #expect(!ProtocolLine.follows(199))
        #expect(!ProtocolLine.follows(201))
        #expect(ProtocolLine.isAbove(1))
        #expect(ProtocolLine.isAbove(200))
        #expect(!ProtocolLine.isAbove(201))
        #expect(!ProtocolLine.isAbove(0))
    }

    // MARK: accessibility

    @Test func voiceOverReadsTheCallersRowWithItsLabel() {
        let mine = Self.row(173, name: "kayak-hollow", margin: 0.12, trend: 9, label: .estimate, isMe: true)
        #expect(ProtocolRowAccessibility.label(mine, locale: Self.enUS)
            == "You, #173, kayak-hollow, 41.2, up 9 since the last update, Estimate")
    }

    @Test func voiceOverReadsAnUnmeasurableRowAsSuch() {
        let dimmed = Self.row(197, label: .notMeasurable, measurable: false)
        #expect(ProtocolRowAccessibility.label(dimmed, locale: Self.enUS) == "#197, Anonymous, 41.2, Not measurable")
        // another network's label is not read: only the caller's chip shows
        let other = Self.row(198, name: "northwind-7", label: .borderline)
        #expect(ProtocolRowAccessibility.label(other, locale: Self.enUS) == "#198, northwind-7, 41.2")
    }

    @Test func voiceOverReadsAClaimedRowsUidOnce() {
        let named = Self.row(196, name: "quiet-harbor", trend: -1, fleets: [SnTopFleetInfo(uid: 212)])
        #expect(ProtocolRowAccessibility.label(named, locale: Self.enUS)
            == "#196, quiet-harbor, 41.2, down 1 since the last update, UID 212")
        let anonymous = Self.row(202, fleets: [SnTopFleetInfo(uid: 77)])
        #expect(ProtocolRowAccessibility.label(anonymous, locale: Self.enUS) == "#202, UID 77, 41.2")
    }

    // MARK: the chart

    @Test func theChartPlotsEachDayOnceOldestFirst() {
        let history = [
            SnTopHistoryPointInfo(day: "2026-10-03", rank: 300, score: 1),
            SnTopHistoryPointInfo(day: "2026-10-01", rank: 412, score: 1),
            SnTopHistoryPointInfo(day: "2026-10-02", rank: 350, score: 1),
            // a day that does not parse, and a day without a rank
            SnTopHistoryPointInfo(day: "yesterday", rank: 10, score: 1),
            SnTopHistoryPointInfo(day: "2026-10-04", rank: 0, score: 1),
        ]
        let points = ProtocolChart.points(history)
        #expect(points.map(\.rank) == [412, 350, 300])
        #expect(points.first?.date == SnTopTime.day("2026-10-01"))
    }

    @Test func theChartKeepsTheLast90Days() {
        let start = SnTopTime.day("2026-01-01")!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let history = (0..<100).map { day in
            SnTopHistoryPointInfo(day: formatter.string(from: start.addingTimeInterval(Double(day) * 86_400)), rank: 500 - day, score: 1)
        }
        let points = ProtocolChart.points(history)
        #expect(points.count == 90)
        #expect(points.last?.rank == 401)
    }

    @Test func theRankAxisAlwaysHoldsThe200Line() {
        let far = [ProtocolChartPoint(date: Date(), rank: 30_000), ProtocolChartPoint(date: Date(), rank: 29_000)]
        let farDomain = ProtocolChart.rankDomain(far)
        #expect(farDomain.contains(200))
        #expect(farDomain.contains(30_000))
        let near = [ProtocolChartPoint(date: Date(), rank: 3)]
        let nearDomain = ProtocolChart.rankDomain(near)
        #expect(nearDomain.lowerBound == 1)
        #expect(nearDomain.contains(200))
    }

    @Test func aTapPicksTheNearestDay() {
        let first = ProtocolChartPoint(date: SnTopTime.day("2026-10-01")!, rank: 412)
        let second = ProtocolChartPoint(date: SnTopTime.day("2026-10-02")!, rank: 350)
        let tap = SnTopTime.day("2026-10-01")!.addingTimeInterval(20 * 3600)
        #expect(ProtocolChart.nearest([first, second], to: tap) == second)
        #expect(ProtocolChart.nearest([], to: tap) == nil)
    }

    // MARK: wire values

    @Test func timesParseWithOrWithoutFractions() {
        #expect(SnTopTime.parse("2026-10-29T21:05:00Z") == Date(timeIntervalSince1970: 1_793_307_900))
        #expect(SnTopTime.parse("2026-10-29T21:05:00.250Z") == Date(timeIntervalSince1970: 1_793_307_900.25))
        #expect(SnTopTime.parse("") == nil)
        #expect(SnTopTime.parse("soon") == nil)
    }

    @Test func labelsAndReasonsReadTheirWireValues() {
        #expect(SnTopLabel(wire: "not_measurable") == .notMeasurable)
        #expect(SnTopLabel(wire: "borderline") == .borderline)
        // a label this app does not know shows no chip
        #expect(SnTopLabel(wire: "excellent") == nil)
        #expect(SnTopNotMeasurableReason(wire: "") == .none)
        #expect(SnTopNotMeasurableReason(wire: "not_in_cohort") == .notInCohort)
        #expect(SnTopNotMeasurableReason(wire: "shared_egress") == .sharedEgress)
        #expect(SnTopNotMeasurableReason(wire: "not_providing") == .notProviding)
        #expect(SnTopNotMeasurableReason(wire: "new_reason") == .other)
    }

    @Test func eachReasonSaysWhyAndAnUnknownOneSaysNothing() {
        #expect(ProtocolText.notMeasurable(.notInCohort) == "Your devices aren't measured by the validator yet.")
        #expect(ProtocolText.notMeasurable(.sharedEgress) == "Your devices share an IP with another network.")
        #expect(ProtocolText.notMeasurable(.notProviding) == "Turn on providing to be ranked.")
        #expect(ProtocolText.notMeasurable(.none) == nil)
        #expect(ProtocolText.notMeasurable(.other) == nil)
    }

    // MARK: paging rules

    @Test func pagesKeepPositionsInOrderOnceEachWithinTheBoard() {
        let shuffled = [3, 1, 2, 2, 401].map { SnTopRowInfo(position: $0) }
        #expect(ProtocolTopRows.firstPage(shuffled).map(\.position) == [1, 2, 3])
        let existing = (1...3).map { SnTopRowInfo(position: $0) }
        let page = [3, 4, 5].map { SnTopRowInfo(position: $0) }
        #expect(ProtocolTopRows.appending(page, to: existing).map(\.position) == [1, 2, 3, 4, 5])
    }

    @Test func theCursorIsFollowedOnlyWithinTheBoard() {
        #expect(ProtocolTopRows.nextCursor("c50", lastPosition: 50) == "c50")
        #expect(ProtocolTopRows.nextCursor("", lastPosition: 50) == nil)
        #expect(ProtocolTopRows.nextCursor(nil, lastPosition: 50) == nil)
        #expect(ProtocolTopRows.nextCursor("c400", lastPosition: 400) == nil)
    }

    @Test func aSeekAsksForEnoughRowsInOneRequest() {
        #expect(ProtocolTopRows.limit(lastPosition: 50, target: nil, pageSize: 50, maxLimit: 200) == 50)
        #expect(ProtocolTopRows.limit(lastPosition: 50, target: 120, pageSize: 50, maxLimit: 200) == 70)
        #expect(ProtocolTopRows.limit(lastPosition: 50, target: 60, pageSize: 50, maxLimit: 200) == 50)
        #expect(ProtocolTopRows.limit(lastPosition: 50, target: 400, pageSize: 50, maxLimit: 200) == 200)
        #expect(ProtocolTopRows.limit(lastPosition: 380, target: 400, pageSize: 50, maxLimit: 200) == 20)
        #expect(ProtocolTopRows.limit(lastPosition: 400, target: nil, pageSize: 50, maxLimit: 200) == 0)
    }
}
