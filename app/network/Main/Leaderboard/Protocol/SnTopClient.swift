//
//  SnTopClient.swift
//  URnetwork
//
//  The Protocol leaderboard's door to the api: GET /sn/top (public, the
//  caller's row too when signed in) and GET /sn/top/me (client auth). A
//  protocol so the store's tests and the previews stand in for the sdk.
//

import Foundation

/// A request that failed. Its cause is never shown or kept: the screen says
/// what could not load, in its own words.
struct SnTopRequestFailed: Error, Equatable {}

/// Each request answers exactly once, on any thread.
protocol SnTopClient: AnyObject {

    /// One page of GET /sn/top, `filter` all. `cursor` "" asks for the first
    /// page; a cursor pins the page to its snapshot. `snapshot` "" is the
    /// latest.
    func fetchTop(
        limit: Int,
        cursor: String,
        snapshot: String,
        _ done: @escaping (Result<SnTopPageInfo, SnTopRequestFailed>) -> Void
    )

    /// GET /sn/top/me: the caller's network in detail.
    func fetchTopMe(_ done: @escaping (Result<SnTopMeResultInfo, SnTopRequestFailed>) -> Void)
}

/**
 * Canned boards for previews: `rowCount` ranked networks with the caller at
 * `myPosition`, the 200 line at 41.2, a few claimed and unmeasurable rows,
 * and 90 days of history climbing over the line. Pages answer at once on the
 * main queue, honouring the limit and the cursor.
 */
final class SnTopPreviewClient: SnTopClient {

    var bindingOpen: Bool
    var rowCount: Int
    var myPosition: Int
    var stale: Bool
    var failing: Bool

    init(bindingOpen: Bool = false, rowCount: Int = 400, myPosition: Int = 173, stale: Bool = false, failing: Bool = false) {
        self.bindingOpen = bindingOpen
        self.rowCount = rowCount
        self.myPosition = myPosition
        self.stale = stale
        self.failing = failing
    }

    static let names = ["stellar-mesh", "", "ridgeline-net", "", "meadow-relay", "harbor-lights", "", "granite-path", "lumen-relay", "cedar-node"]
    static let tags = ["🐬", "", "🔥", "🌲", "", "⚡️", "", "🛰️", "", "🌙"]

    var snapshot: SnTopSnapshotInfo {
        SnTopSnapshotInfo(
            id: "preview",
            tempoIndex: 1200,
            block: 6_400_000,
            computedAt: Date().addingTimeInterval(stale ? -6 * 3600 : -1200),
            settlementEpoch: 42,
            totalRanked: 41_230,
            headSeats: 200,
            claimedFleets: 3,
            openSeats: 197,
            projectedCutoff: 41.2,
            claimedCutoff: 12.5,
            bindingOpen: bindingOpen,
            bindingNote: bindingOpen ? "" : "Top 200 binding isn't open on mainnet yet",
            measuredProviders: 1200,
            cohortCapacity: 1500,
            precisionAt200: nil,
            stale: stale
        )
    }

    func row(_ position: Int) -> SnTopRowInfo {
        let score = 41.2 * pow(1.012, Double(200 - position))
        let isMe = position == myPosition
        let measurable = position % 7 != 4
        let name = isMe ? "kayak-hollow" : Self.names[position % Self.names.count]
        var fleets: [SnTopFleetInfo] = []
        if position == 1 || position == 3 || position == 202 {
            fleets = [SnTopFleetInfo(
                uid: Int64([1: 81, 3: 119, 202: 77][position] ?? 0),
                generation: 2,
                validToEpoch: 16,
                replicaScore: score,
                validatorScore: score,
                validatorRank: position == 202 ? 3 : (position == 1 ? 1 : 2),
                validatorRankOf: 3,
                selected: true,
                incentive: position == 1 ? 0.018 : 0.006,
                incentiveStale: position == 1
            )]
        }
        let margin = (score - 41.2) / 41.2
        return SnTopRowInfo(
            position: position,
            name: fleets.isEmpty || position != 3 ? name : "",
            tag: Self.tags[position % Self.tags.count],
            projectedScore: score,
            rawLastTempo: score,
            margin: margin,
            trend: [0, 1, -1, 3, -2, 0, 1][position % 7],
            prefixes: max(1, Int(score / 2)),
            sharedPrefixes: position % 4,
            presence: 0.9,
            label: measurable ? .estimate : .notMeasurable,
            measurable: measurable,
            verifyEligible: measurable,
            claimPrompt: measurable && position <= 200,
            isMe: isMe,
            fleets: fleets
        )
    }

    var me: SnTopMeInfo {
        var history: [SnTopHistoryPointInfo] = []
        let calendar = Calendar(identifier: .gregorian)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for day in 0..<90 {
            let date = calendar.date(byAdding: .day, value: day - 89, to: Date()) ?? Date()
            let rank = Int(412 - Double(412 - myPosition) * Double(day) / 89)
            history.append(SnTopHistoryPointInfo(day: formatter.string(from: date), rank: rank, score: 41.2))
        }
        return SnTopMeInfo(
            row: row(myPosition),
            soloScore: 21.4,
            distinctPrefixes: 18,
            sharedPrefixes: 3,
            sharedWithUnits: 4,
            notMeasurableReason: .none,
            history: history
        )
    }

    func fetchTop(limit: Int, cursor: String, snapshot: String, _ done: @escaping (Result<SnTopPageInfo, SnTopRequestFailed>) -> Void) {
        let failing = self.failing
        let start = (Int(cursor) ?? 0) + 1
        let end = min(rowCount, start + limit - 1, 400)
        let rows = start <= end ? (start...end).map { row($0) } : []
        let page = SnTopPageInfo(
            snapshot: self.snapshot,
            rows: rows,
            me: myPosition > 0 ? row(myPosition) : nil,
            next: end < min(rowCount, 400) ? String(end) : nil
        )
        DispatchQueue.main.async {
            done(failing ? .failure(SnTopRequestFailed()) : .success(page))
        }
    }

    func fetchTopMe(_ done: @escaping (Result<SnTopMeResultInfo, SnTopRequestFailed>) -> Void) {
        let failing = self.failing
        let result = SnTopMeResultInfo(snapshot: snapshot, me: me)
        DispatchQueue.main.async {
            done(failing ? .failure(SnTopRequestFailed()) : .success(result))
        }
    }
}
