//
//  SnTopAnswersTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The sdk's Api.SnTop and Api.SnTopMe results as the Protocol board takes
 * them (SnTopAnswers): a nullable number's Has flag becomes an optional, a
 * nil time stays nil, the last page's "" cursor ends the list, and any
 * request or result error, or a result without its snapshot, is a failure.
 * Built from real sdk objects; nothing is sent.
 */
struct SnTopAnswersTests {

    private static func snapshot(claimedCutoff: Double? = nil, precision: Double? = nil) -> SdkSnTopSnapshot {
        let snapshot = SdkSnTopSnapshot()
        snapshot.id_ = "s1"
        snapshot.tempoIndex = 1200
        snapshot.block = 6_400_000
        snapshot.computedAt = SdkNewTimeUnixMilli(1_793_307_900_000)
        snapshot.settlementEpoch = 42
        snapshot.totalRanked = 41_230
        snapshot.headSeats = 200
        snapshot.claimedFleets = 3
        snapshot.openSeats = 197
        snapshot.projectedCutoff = 41.2
        if let claimedCutoff {
            snapshot.claimedCutoff = claimedCutoff
            snapshot.hasClaimedCutoff = true
        }
        snapshot.bindingOpen = false
        snapshot.bindingNote = "Top 200 binding isn't open on mainnet yet"
        snapshot.measuredProviders = 1200
        snapshot.cohortCapacity = 1500
        if let precision {
            snapshot.precisionAt200 = precision
            snapshot.hasPrecisionAt200 = true
        }
        snapshot.stale = true
        return snapshot
    }

    private static func row(_ position: Int, fleets: [SdkSnTopFleet] = []) -> SdkSnTopRow {
        let row = SdkSnTopRow()
        row.position = position
        row.name = position == 1 ? "kayak-hollow" : ""
        row.tag = "🐬"
        row.projectedScore = 312.4
        row.rawLastTempo = 300
        row.margin = 0.12
        row.trend = -2
        row.prefixes = 18
        row.sharedPrefixes = 3
        row.presence = 0.9
        row.label = SdkSnTopLabelBorderline
        row.measurable = true
        row.verifyEligible = true
        row.claimPrompt = true
        row.isMe = position == 1
        let list = SdkNewSnTopFleetList()
        for fleet in fleets {
            list?.add(fleet)
        }
        row.fleets = list
        return row
    }

    @Test func aPageKeepsItsRowsInOrderAndItsCursor() throws {
        let result = SdkSnTopResult()
        result.snapshot = Self.snapshot()
        let rows = SdkNewSnTopRowList()
        rows?.add(Self.row(1))
        rows?.add(Self.row(2))
        result.rows = rows
        result.me = Self.row(1)
        result.next = "c50"

        let page = try SnTopAnswers.page(result, err: nil).get()
        #expect(page.rows.map(\.position) == [1, 2])
        #expect(page.next == "c50")
        #expect(page.me?.isMe == true)
        let first = try #require(page.rows.first)
        #expect(first.name == "kayak-hollow")
        #expect(first.tag == "🐬")
        #expect(first.trend == -2)
        #expect(first.label == .borderline)
        #expect(first.claimPrompt)
        #expect(page.rows[1].name == "")
    }

    @Test func theLastPagesEmptyCursorEndsTheList() throws {
        let result = SdkSnTopResult()
        result.snapshot = Self.snapshot()
        result.rows = SdkNewSnTopRowList()
        result.next = ""
        let page = try SnTopAnswers.page(result, err: nil).get()
        #expect(page.next == nil)
        #expect(page.rows.isEmpty)
        #expect(page.me == nil)
    }

    @Test func aNullableNumberIsAnOptional() throws {
        let unset = SnTopAnswers.snapshot(Self.snapshot())
        #expect(unset.claimedCutoff == nil)
        #expect(unset.precisionAt200 == nil)
        let set = SnTopAnswers.snapshot(Self.snapshot(claimedCutoff: 0, precision: 0.93))
        // a value of zero that the server sent is a value
        #expect(set.claimedCutoff == 0)
        #expect(set.precisionAt200 == 0.93)
    }

    @Test func theSnapshotKeepsItsTimesAndCounts() {
        let snapshot = SnTopAnswers.snapshot(Self.snapshot())
        #expect(snapshot.id == "s1")
        #expect(snapshot.tempoIndex == 1200)
        #expect(snapshot.computedAt == Date(timeIntervalSince1970: 1_793_307_900))
        // null times stay nil
        #expect(snapshot.validatorSummaryAt == nil)
        #expect(snapshot.incentiveAt == nil)
        #expect(snapshot.totalRanked == 41_230)
        #expect(!snapshot.bindingOpen)
        #expect(snapshot.stale)
    }

    @Test func aFleetsUnknownValidatorAndChainValuesAreNil() {
        let bare = SdkSnTopFleet()
        bare.uid = 77
        bare.generation = 1
        bare.validToEpoch = 9
        bare.replicaScore = 40.7
        let fleet = SnTopAnswers.fleet(bare)
        #expect(fleet == SnTopFleetInfo(uid: 77, generation: 1, validToEpoch: 9, replicaScore: 40.7))

        let known = SdkSnTopFleet()
        known.uid = 81
        known.validatorScore = 312.4
        known.hasValidatorScore = true
        known.validatorRank = 1
        known.hasValidatorRank = true
        known.validatorRankOf = 142
        known.hasValidatorRankOf = true
        // not selected is a value, not unknown
        known.selected = false
        known.hasSelected = true
        known.incentive = 0.018
        known.hasIncentive = true
        known.incentiveStale = true
        let mapped = SnTopAnswers.fleet(known)
        #expect(mapped.validatorScore == 312.4)
        #expect(mapped.validatorRank == 1)
        #expect(mapped.validatorRankOf == 142)
        #expect(mapped.selected == false)
        #expect(mapped.incentive == 0.018)
        #expect(mapped.incentiveStale)
    }

    @Test func aClaimedRowCarriesItsFleets() throws {
        let fleet = SdkSnTopFleet()
        fleet.uid = 212
        let mapped = SnTopAnswers.row(Self.row(196, fleets: [fleet]))
        #expect(mapped.fleets.map(\.uid) == [212])
        #expect(mapped.claimed)
    }

    @Test func theCallersDetailKeepsItsHistoryAndReason() throws {
        let me = SdkSnTopMe()
        me.row = Self.row(1)
        me.soloScore = 21.4
        me.distinctPrefixes = 18
        me.sharedPrefixes = 3
        me.sharedWithUnits = 4
        me.notMeasurableReason = SdkSnTopNotMeasurableReasonSharedEgress
        let history = SdkNewSnTopHistoryPointList()
        let point = SdkSnTopHistoryPoint()
        point.day = "2026-10-29"
        point.rank = 173
        point.score = 41.2
        history?.add(point)
        me.history = history

        let result = SdkSnTopMeResult()
        result.snapshot = Self.snapshot()
        result.me = me
        let answer = try SnTopAnswers.me(result, err: nil).get()
        #expect(answer.me.rankedRow?.position == 1)
        #expect(answer.me.soloScore == 21.4)
        #expect(answer.me.distinctPrefixes == 18)
        #expect(answer.me.sharedWithUnits == 4)
        #expect(answer.me.notMeasurableReason == .sharedEgress)
        #expect(answer.me.history == [SnTopHistoryPointInfo(day: "2026-10-29", rank: 173, score: 41.2)])
    }

    @Test func errorsAndMissingSnapshotsAreFailures() {
        struct Offline: Error {}
        #expect(throws: SnTopRequestFailed.self) {
            try SnTopAnswers.page(nil, err: Offline()).get()
        }
        #expect(throws: SnTopRequestFailed.self) {
            try SnTopAnswers.page(nil, err: nil).get()
        }
        let refused = SdkSnTopResult()
        refused.snapshot = Self.snapshot()
        let error = SdkApiError()
        error.message = "404 page not found"
        refused.error = error
        #expect(throws: SnTopRequestFailed.self) {
            try SnTopAnswers.page(refused, err: nil).get()
        }
        // a result with no snapshot ranks nothing it can be read against
        let bare = SdkSnTopResult()
        #expect(throws: SnTopRequestFailed.self) {
            try SnTopAnswers.page(bare, err: nil).get()
        }
        let noMe = SdkSnTopMeResult()
        noMe.snapshot = Self.snapshot()
        #expect(throws: SnTopRequestFailed.self) {
            try SnTopAnswers.me(noMe, err: nil).get()
        }
    }
}
