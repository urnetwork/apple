//
//  SnTopSdkClient.swift
//  URnetwork
//
//  The sdk's Api as the Protocol leaderboard's client: Api.SnTop (GET
//  /sn/top) and Api.SnTopMe (GET /sn/top/me), with their results as the
//  board's plain values.
//

import Foundation
import URnetworkSdk

enum SnTopSdk {

    /// The session's api as the board's client; nil without one.
    static func client(_ api: SdkApi?) -> SnTopClient? {
        api
    }
}

/// The sdk's answers as the board takes them. A request error, a result
/// error, or a result without its snapshot is a failure, and the server's
/// message is never kept. A nullable number the sdk carries as a value with
/// a Has flag becomes an optional.
enum SnTopAnswers {

    static func page(_ result: SdkSnTopResult?, err: Error?) -> Result<SnTopPageInfo, SnTopRequestFailed> {
        if let err {
            return .failure(SnTopRequestFailed(snapshotExpired: httpStatus(err) == 410))
        }
        guard let result, result.error == nil, let snapshot = result.snapshot else {
            return .failure(SnTopRequestFailed())
        }
        var rows: [SnTopRowInfo] = []
        if let list = result.rows {
            rows.reserveCapacity(list.len())
            for i in 0..<list.len() {
                if let row = list.get(i) {
                    rows.append(Self.row(row))
                }
            }
        }
        return .success(SnTopPageInfo(
            snapshot: Self.snapshot(snapshot),
            rows: rows,
            me: result.me.map { Self.row($0) },
            // "" on the last page
            next: result.next.isEmpty ? nil : result.next
        ))
    }

    static func me(_ result: SdkSnTopMeResult?, err: Error?) -> Result<SnTopMeResultInfo, SnTopRequestFailed> {
        guard err == nil, let result, result.error == nil, let snapshot = result.snapshot, let me = result.me else {
            return .failure(SnTopRequestFailed())
        }
        return .success(SnTopMeResultInfo(snapshot: Self.snapshot(snapshot), me: Self.me(me)))
    }

    static func snapshot(_ snapshot: SdkSnTopSnapshot) -> SnTopSnapshotInfo {
        SnTopSnapshotInfo(
            id: snapshot.id_,
            tempoIndex: snapshot.tempoIndex,
            block: snapshot.block,
            computedAt: date(snapshot.computedAt),
            settlementEpoch: snapshot.settlementEpoch,
            totalRanked: snapshot.totalRanked,
            headSeats: snapshot.headSeats,
            claimedFleets: snapshot.claimedFleets,
            openSeats: snapshot.openSeats,
            projectedCutoff: snapshot.projectedCutoff,
            claimedCutoff: snapshot.hasClaimedCutoff ? snapshot.claimedCutoff : nil,
            bindingOpen: snapshot.bindingOpen,
            bindingNote: snapshot.bindingNote,
            measuredProviders: snapshot.measuredProviders,
            cohortCapacity: snapshot.cohortCapacity,
            validatorSummaryAt: date(snapshot.validatorSummaryAt),
            incentiveAt: date(snapshot.incentiveAt),
            precisionAt200: snapshot.hasPrecisionAt200 ? snapshot.precisionAt200 : nil,
            stale: snapshot.stale
        )
    }

    static func row(_ row: SdkSnTopRow) -> SnTopRowInfo {
        var fleets: [SnTopFleetInfo] = []
        if let list = row.fleets {
            fleets.reserveCapacity(list.len())
            for i in 0..<list.len() {
                if let fleet = list.get(i) {
                    fleets.append(Self.fleet(fleet))
                }
            }
        }
        return SnTopRowInfo(
            position: row.position,
            name: row.name,
            tag: row.tag,
            projectedScore: row.projectedScore,
            rawLastTempo: row.rawLastTempo,
            margin: row.margin,
            trend: row.trend,
            prefixes: row.prefixes,
            sharedPrefixes: row.sharedPrefixes,
            presence: row.presence,
            label: SnTopLabel(wire: row.label),
            measurable: row.measurable,
            verifyEligible: row.verifyEligible,
            claimPrompt: row.claimPrompt,
            isMe: row.isMe,
            fleets: fleets
        )
    }

    static func fleet(_ fleet: SdkSnTopFleet) -> SnTopFleetInfo {
        SnTopFleetInfo(
            uid: fleet.uid,
            generation: fleet.generation,
            validToEpoch: fleet.validToEpoch,
            replicaScore: fleet.replicaScore,
            validatorScore: fleet.hasValidatorScore ? fleet.validatorScore : nil,
            validatorRank: fleet.hasValidatorRank ? fleet.validatorRank : nil,
            validatorRankOf: fleet.hasValidatorRankOf ? fleet.validatorRankOf : nil,
            selected: fleet.hasSelected ? fleet.selected : nil,
            incentive: fleet.hasIncentive ? fleet.incentive : nil,
            incentiveStale: fleet.incentiveStale
        )
    }

    static func me(_ me: SdkSnTopMe) -> SnTopMeInfo {
        var history: [SnTopHistoryPointInfo] = []
        if let list = me.history {
            history.reserveCapacity(list.len())
            for i in 0..<list.len() {
                if let point = list.get(i) {
                    history.append(SnTopHistoryPointInfo(day: point.day, rank: point.rank, score: point.score))
                }
            }
        }
        return SnTopMeInfo(
            row: me.row.map { Self.row($0) },
            soloScore: me.soloScore,
            distinctPrefixes: me.distinctPrefixes,
            sharedPrefixes: me.sharedPrefixes,
            sharedWithUnits: me.sharedWithUnits,
            notMeasurableReason: SnTopNotMeasurableReason(wire: me.notMeasurableReason),
            history: history
        )
    }

    /// The http status a refusal carries: the sdk passes connect's
    /// HttpStatusError on as its text, "<code> <text>: <body>" ("410 Gone:
    /// The snapshot expired. Reload from the top."); nil for any other
    /// failure.
    static func httpStatus(_ error: Error) -> Int? {
        let message = (error as NSError).localizedDescription
        guard let first = message.split(separator: " ", maxSplits: 1).first,
              first.count == 3,
              let code = Int(first),
              100 <= code && code <= 599 else {
            return nil
        }
        return code
    }

    /// nil means null
    static func date(_ time: SdkTime?) -> Date? {
        guard let time else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(time.unixMilli()) / 1000)
    }
}

extension SdkApi: SnTopClient {

    func fetchTop(
        limit: Int,
        cursor: String,
        snapshot: String,
        _ done: @escaping (Result<SnTopPageInfo, SnTopRequestFailed>) -> Void
    ) {
        let args = SdkSnTopArgs()
        args.limit = limit
        args.cursor = cursor
        args.filter = SdkSnTopFilterAll
        args.snapshot = snapshot
        snTop(args, callback: SnTopPageCallback { result, err in
            done(SnTopAnswers.page(result, err: err))
        })
    }

    func fetchTopMe(_ done: @escaping (Result<SnTopMeResultInfo, SnTopRequestFailed>) -> Void) {
        snTopMe(SnTopMeCallback { result, err in
            done(SnTopAnswers.me(result, err: err))
        })
    }
}

private class SnTopPageCallback: OneShotSdkCallback<SdkSnTopResult, SdkSnTopCallbackProtocol>, SdkSnTopCallbackProtocol {
    func result(_ result: SdkSnTopResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnTopMeCallback: OneShotSdkCallback<SdkSnTopMeResult, SdkSnTopMeCallbackProtocol>, SdkSnTopMeCallbackProtocol {
    func result(_ result: SdkSnTopMeResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
