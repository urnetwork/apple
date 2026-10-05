//
//  SnPayoutLineTests.swift
//  networkTests
//
//  The SN payout line at the foot of the points card: which line shows (no
//  coldkey, nothing claimable, claimable), the epoch end, claim-open and
//  expiry times formatted from the sdk's epoch schedule, the schedule carried
//  from the claims read into the line, and the final USDC payout line.
//

import Foundation
import Testing
@testable import URnetwork

@MainActor
struct SnPayoutLineTests {

    // the sdk's schedule for an epoch closing 2026-10-13 00:00 UTC on the
    // mainnet policy: claims open 14,400 blocks (two days) later, and the
    // share expires at the end of epoch e+9 (453,600 blocks after the close,
    // less one block)
    // nonisolated: the line helper's default arguments read them
    nonisolated private static let schedule = SnEpochScheduleInfo(
        epoch: 9,
        endMillis: 1_791_849_600_000,
        claimOpenMillis: 1_791_849_600_000 + 14_400 * 12_000,
        expiryMillis: 1_791_849_600_000 + (453_600 - 1) * 12_000
    )

    // 2026-10-06 00:00 UTC, a week before the close
    nonisolated private static let now: Int64 = 1_791_244_800_000

    /// names each time by the millis it was formatted from
    private static func tag(_ millis: Int64) -> String {
        "t\(millis)"
    }

    private static let taggedTimes = SnPayoutTimes(
        epochEnd: "t\(schedule.endMillis)",
        claimOpen: "t\(schedule.claimOpenMillis)",
        expiry: "t\(schedule.expiryMillis)"
    )

    /// recent ICU data puts a narrow no-break space before the meridiem
    private static func format(_ millis: Int64, _ locale: String, _ zone: String) -> String {
        SnPayoutLine.formatTime(
            millis,
            timeZone: TimeZone(identifier: zone)!,
            locale: Locale(identifier: locale)
        )
        .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private static func line(
        walletKnown: Bool = true,
        hasColdkey: Bool = true,
        totalClaimableRao: Int64 = 0,
        schedule: SnEpochScheduleInfo? = SnPayoutLineTests.schedule,
        nowMillis: Int64 = SnPayoutLineTests.now
    ) -> SnPayoutLine? {
        SnPayoutLine.of(
            walletKnown: walletKnown,
            hasColdkey: hasColdkey,
            totalClaimableRao: totalClaimableRao,
            schedule: schedule,
            nowMillis: nowMillis,
            formatTime: tag
        )
    }

    @Test func noColdkeyAsksForOne() {
        #expect(Self.line(hasColdkey: false) == .setColdkey)
        // alpha goes only to a coldkey, whatever the chain says
        #expect(Self.line(hasColdkey: false, totalClaimableRao: 3_241_000_000) == .setColdkey)
        #expect(Self.line(hasColdkey: false, schedule: nil) == .setColdkey)
    }

    @Test func nothingShowsWhileTheColdkeyIsUnknown() {
        #expect(Self.line(walletKnown: false, hasColdkey: false) == nil)
        #expect(Self.line(walletKnown: false, totalClaimableRao: 3_241_000_000) == nil)
    }

    @Test func nothingClaimableExplainsTheScheduleWithoutClaim() {
        #expect(Self.line() == .schedule(times: Self.taggedTimes, claimable: false))
    }

    @Test func somethingClaimableAddsClaim() {
        #expect(Self.line(totalClaimableRao: 3_241_000_000) == .schedule(times: Self.taggedTimes, claimable: true))
    }

    @Test func withoutTheScheduleTheExplanationStandsAlone() {
        #expect(Self.line(schedule: nil) == .schedule(times: nil, claimable: false))
        #expect(Self.line(totalClaimableRao: 1, schedule: nil) == .schedule(times: nil, claimable: true))
    }

    @Test func anEndedEpochWaitsForTheNextRead() {
        #expect(Self.line(nowMillis: Self.schedule.endMillis) == .schedule(times: nil, claimable: false))
        #expect(Self.line(nowMillis: Self.schedule.endMillis - 1) == .schedule(times: Self.taggedTimes, claimable: false))
    }

    @Test func theTimesAreLocalDatesAndTimes() {
        let line = SnPayoutLine.of(
            walletKnown: true,
            hasColdkey: true,
            totalClaimableRao: 0,
            schedule: Self.schedule,
            nowMillis: Self.now,
            formatTime: { Self.format($0, "en_US", "UTC") }
        )
        #expect(line == .schedule(
            times: SnPayoutTimes(
                epochEnd: "Oct 13, 2026 at 12:00 AM",
                claimOpen: "Oct 15, 2026 at 12:00 AM",
                expiry: "Dec 14, 2026 at 11:59 PM"
            ),
            claimable: false
        ))
    }

    @Test func theTimesFollowTheReadersZoneAndLocale() {
        #expect(Self.format(Self.schedule.endMillis, "en_US", "America/Los_Angeles") == "Oct 12, 2026 at 5:00 PM")
        #expect(Self.format(Self.schedule.claimOpenMillis, "de_DE", "Europe/Berlin") == "15.10.2026, 02:00")
    }

    @Test func theClaimsReadCarriesTheScheduleIntoTheLine() async {
        let wallet = SnWalletInfo(coldkeySs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY", clientId: "", setAtMillis: 0)
        let claimable = SnEpochClaimInfo(
            epoch: 8,
            shareBps: 71,
            amountRao: 3_241_000_000,
            status: .claimable,
            claimOpenBlock: 0,
            expiryBlock: 0,
            txHash: ""
        )
        let viewModel = EarningsViewModel(client: EarningsPreviewClient(
            wallet: wallet,
            claims: [claimable],
            schedule: Self.schedule
        ))
        // the wallet read has not settled yet
        #expect(viewModel.payoutLine(nowMillis: Self.now, formatTime: Self.tag) == nil)

        await viewModel.refresh()
        #expect(viewModel.schedule == Self.schedule)
        #expect(viewModel.payoutLine(nowMillis: Self.now, formatTime: Self.tag) == .schedule(times: Self.taggedTimes, claimable: true))

        let noWallet = EarningsViewModel(client: EarningsPreviewClient(schedule: Self.schedule))
        await noWallet.refresh()
        #expect(noWallet.payoutLine(nowMillis: Self.now, formatTime: Self.tag) == .setColdkey)
    }

    @Test func theUsdcLineIsTheFinalUsdcPayoutWhilePending() async {
        #expect(UsdcFormat.finalPayoutWaiting("3.87") == "Final USDC payout: 3.87 USDC waiting")

        let client = FakeUsdcWalletsClient()
        client.paymentRows = [
            UsdcPaymentInfo(id: "held", walletId: nil, payoutNanoCents: 3_870_000_000, tokenAmount: 0, completed: false, canceled: false, completeTimeMillis: nil),
        ]
        let viewModel = UsdcWalletsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.showsPendingLine)
        #expect(viewModel.pendingUsd.map(UsdcFormat.finalPayoutWaiting) == "Final USDC payout: 3.87 USDC waiting")

        // paid out: the line is gone
        client.paymentRows = [
            UsdcPaymentInfo(id: "held", walletId: nil, payoutNanoCents: 3_870_000_000, tokenAmount: 3.87, completed: true, canceled: false, completeTimeMillis: 1),
        ]
        await viewModel.refresh()
        #expect(!viewModel.showsPendingLine)
        #expect(viewModel.pendingUsd == nil)
    }
}
