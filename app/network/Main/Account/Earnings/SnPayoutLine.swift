//
//  SnPayoutLine.swift
//  URnetwork
//
//  The SN payout line at the foot of the points card: how and when a
//  provider is paid since payouts moved to the UR subnet (WHITEPAPER §5.2,
//  §8.3). Earnings settle every epoch and are paid in SN25α to the Bittensor
//  coldkey once the provider claims them; the app never claims by itself.
//  The times are the current epoch's schedule from the SDK (the
//  coordinator's policy), never durations written into the copy.
//

import Foundation

/// The current epoch's settlement times, from the SDK's SnEpochSchedule.
struct SnEpochScheduleInfo: Equatable {
    let epoch: Int64
    let endMillis: Int64
    let claimOpenMillis: Int64
    let expiryMillis: Int64
}

/// The three times "This epoch ends …" names, formatted for the reader.
struct SnPayoutTimes: Equatable {
    let epochEnd: String
    let claimOpen: String
    let expiry: String
}

/// What the foot of the points card says about payouts.
enum SnPayoutLine: Equatable {
    /// no coldkey yet: "Set your Bittensor coldkey to get paid", and the
    /// action opens the coldkey flow
    case setColdkey
    /// the explanation, then the current epoch's times when the schedule is
    /// known; claimable adds the Claim action
    case schedule(times: SnPayoutTimes?, claimable: Bool)

    /// The line for the card, or nil while it is not known whether a coldkey
    /// is set (the wallet is loading, or its read failed with none cached). A
    /// schedule whose epoch has already ended waits for the next refresh
    /// rather than show a past end.
    static func of(
        walletKnown: Bool,
        hasColdkey: Bool,
        totalClaimableRao: Int64,
        schedule: SnEpochScheduleInfo?,
        nowMillis: Int64,
        formatTime: (Int64) -> String
    ) -> SnPayoutLine? {
        guard walletKnown else {
            return nil
        }
        guard hasColdkey else {
            return .setColdkey
        }
        var times: SnPayoutTimes?
        if let schedule, nowMillis < schedule.endMillis {
            times = SnPayoutTimes(
                epochEnd: formatTime(schedule.endMillis),
                claimOpen: formatTime(schedule.claimOpenMillis),
                expiry: formatTime(schedule.expiryMillis)
            )
        }
        return .schedule(times: times, claimable: totalClaimableRao > 0)
    }

    /// A schedule time as the reader's local date and time
    /// ("Oct 11, 2026 at 2:00 PM").
    static func formatTime(_ millis: Int64, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        formatter.locale = locale
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}
