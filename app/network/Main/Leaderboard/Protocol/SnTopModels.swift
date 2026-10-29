//
//  SnTopModels.swift
//  URnetwork
//
//  The Protocol leaderboard's data (owner decision 2026-10-29, LEADERTOP):
//  GET /sn/top and GET /sn/top/me as plain values, so the views, the store
//  and the tests never hold gomobile objects. They mirror the sdk's SnTop
//  shapes (server/LEADERTOP.md §7, the implementation contract); a nullable
//  number the sdk carries as a value plus a Has<Field> flag is an optional.
//

import Foundation

/// A row's recommendation label (server/LEADERTOP.md §5.6, Q13, Q17).
enum SnTopLabel: String, Equatable, CaseIterable {
    /// before the board's measured precision at 200 reaches 90%
    case estimate
    case likely
    case borderline
    case unlikely
    case notMeasurable = "not_measurable"

    /// The label the server sent; nil for one this app does not know, which
    /// shows no chip rather than a wrong one.
    init?(wire: String) {
        self.init(rawValue: wire)
    }
}

/// Why the validator cannot score the caller's network (GET /sn/top/me).
enum SnTopNotMeasurableReason: Equatable {
    case none
    case notInCohort
    case sharedEgress
    case notProviding
    /// a reason this app does not know: the card says only "Not measurable"
    case other

    init(wire: String) {
        switch wire {
        case "":
            self = .none
        case "not_in_cohort":
            self = .notInCohort
        case "shared_egress":
            self = .sharedEgress
        case "not_providing":
            self = .notProviding
        default:
            self = .other
        }
    }
}

/// One ranking, computed once per tempo (about 72 minutes).
struct SnTopSnapshotInfo: Equatable {
    var id: String
    var tempoIndex: Int64 = 0
    var block: Int64 = 0
    /// nil when the server's time could not be read
    var computedAt: Date? = nil
    var settlementEpoch: Int64 = 0
    var totalRanked: Int = 0
    var headSeats: Int = 200
    var claimedFleets: Int = 0
    var openSeats: Int = 0
    /// the projected 200th score across all units: the 200 line
    var projectedCutoff: Double = 0
    /// the current floor among claimed fleets
    var claimedCutoff: Double? = nil
    /// fleet binding (claiming a UID) is open on mainnet
    var bindingOpen: Bool = false
    var bindingNote: String = ""
    var measuredProviders: Int = 0
    var cohortCapacity: Int = 0
    var validatorSummaryAt: Date? = nil
    var incentiveAt: Date? = nil
    var precisionAt200: Double? = nil
    /// computed more than 3 tempos ago
    var stale: Bool = false
}

/// A claimed fleet of a network: its UID on SN25 and what the validator and
/// the chain say about it.
struct SnTopFleetInfo: Equatable, Identifiable {
    var uid: Int64
    var generation: Int64 = 0
    var validToEpoch: Int64 = 0
    /// the board's exact replica of the validator's score
    var replicaScore: Double = 0
    var validatorScore: Double? = nil
    var validatorRank: Int? = nil
    /// how many claimed fleets the validator ranked
    var validatorRankOf: Int? = nil
    /// selected into the head this tempo
    var selected: Bool? = nil
    /// the UID's on-chain incentive, a fraction of the subnet's
    var incentive: Double? = nil
    var incentiveStale: Bool = false

    var id: Int64 {
        uid
    }
}

/// One ranked network. Anonymous rows carry no name and no network id.
struct SnTopRowInfo: Equatable, Identifiable {
    /// 1-based, no ties
    var position: Int
    /// "" when the network has not opted in to showing its name
    var name: String = ""
    /// the network's emoji tag, "" for none
    var tag: String = ""
    var projectedScore: Double = 0
    var rawLastTempo: Double = 0
    /// a fraction of the projected cutoff: + above the 200 line, − below it
    var margin: Double = 0
    /// positions moved since the previous tempo, + up
    var trend: Int = 0
    var prefixes: Int = 0
    var sharedPrefixes: Int = 0
    var presence: Double = 0
    var label: SnTopLabel? = nil
    var measurable: Bool = true
    var verifyEligible: Bool = true
    /// measurable and projected inside the top 200
    var claimPrompt: Bool = false
    var isMe: Bool = false
    /// empty when unclaimed
    var fleets: [SnTopFleetInfo] = []

    var id: Int {
        position
    }

    var claimed: Bool {
        !fleets.isEmpty
    }
}

/// One day of the caller's projected rank.
struct SnTopHistoryPointInfo: Equatable {
    /// YYYY-MM-DD
    var day: String
    var rank: Int
    var score: Double
}

/// The caller's network in detail (GET /sn/top/me).
struct SnTopMeInfo: Equatable {
    /// nil, or a position of 0, when the network is not ranked
    var row: SnTopRowInfo? = nil
    /// the score if nobody else sharing its prefixes claimed (Q4)
    var soloScore: Double = 0
    var distinctPrefixes: Int = 0
    var sharedPrefixes: Int = 0
    var sharedWithUnits: Int = 0
    var notMeasurableReason: SnTopNotMeasurableReason = .none
    /// daily, oldest first, at most 90
    var history: [SnTopHistoryPointInfo] = []

    /// the row, when the network is ranked
    var rankedRow: SnTopRowInfo? {
        guard let row, row.position > 0 else {
            return nil
        }
        return row
    }
}

/// One page of GET /sn/top.
struct SnTopPageInfo: Equatable {
    var snapshot: SnTopSnapshotInfo
    var rows: [SnTopRowInfo]
    /// the caller's row wherever it ranks; nil when not signed in or not ranked
    var me: SnTopRowInfo? = nil
    /// the next page's cursor, nil at the end
    var next: String? = nil
}

/// GET /sn/top/me.
struct SnTopMeResultInfo: Equatable {
    var snapshot: SnTopSnapshotInfo
    var me: SnTopMeInfo
}

/// The board's times as the server sends them.
enum SnTopTime {

    /// An RFC 3339 time, with or without fractional seconds; nil for "" or
    /// anything else.
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: trimmed)
    }

    /// A history day, YYYY-MM-DD, as the start of that day in UTC; nil for
    /// anything else.
    static func day(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}
