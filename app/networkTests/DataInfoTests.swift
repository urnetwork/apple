import Foundation
import Testing
@testable import URnetwork

/// The "About your data" sheet: when the free data refreshes (the next 00:00
/// UTC, whatever the device time zone), the countdown to it, the Used,
/// Pending and Available split from a balance, the daily amount from the
/// server's start_balance_byte_count, and when each entry point shows.
struct DataInfoTests {

    private static let gib = 1024 * 1024 * 1024
    private static let tib = 1024 * gib

    private static func utc(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        millis: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
        return date.addingTimeInterval(Double(millis) / 1000)
    }

    // MARK: the next refresh

    @Test func nextRefreshIsTheNextUtcMidnight() {
        #expect(nextFreeRefresh(after: Self.utc(2026, 10, 4, 12, 34, 56)) == Self.utc(2026, 10, 5))
        #expect(nextFreeRefresh(after: Self.utc(2026, 10, 4, 0, 0, 0, millis: 1)) == Self.utc(2026, 10, 5))
    }

    @Test func nextRefreshAroundMidnight() {
        // just before midnight the refresh is a millisecond away
        #expect(nextFreeRefresh(after: Self.utc(2026, 10, 4, 23, 59, 59, millis: 999)) == Self.utc(2026, 10, 5))
        // at midnight it has just happened: the next one is a day away
        #expect(nextFreeRefresh(after: Self.utc(2026, 10, 5)) == Self.utc(2026, 10, 6))
        #expect(nextFreeRefresh(after: Self.utc(2026, 10, 5, 0, 0, 0, millis: 1)) == Self.utc(2026, 10, 6))
    }

    @Test func nextRefreshRollsOverMonthsYearsAndLeapDays() {
        #expect(nextFreeRefresh(after: Self.utc(2026, 10, 31, 18)) == Self.utc(2026, 11, 1))
        #expect(nextFreeRefresh(after: Self.utc(2026, 12, 31, 23, 30)) == Self.utc(2027, 1, 1))
        #expect(nextFreeRefresh(after: Self.utc(2028, 2, 28, 10)) == Self.utc(2028, 2, 29))
        #expect(nextFreeRefresh(after: Self.utc(2028, 2, 29, 10)) == Self.utc(2028, 3, 1))
    }

    // MARK: the countdown

    @Test func countdownInHoursAndMinutes() {
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 18, 48)) == RefreshCountdown(hours: 5, minutes: 12))
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 0, 1)) == RefreshCountdown(hours: 23, minutes: 59))
        // the refresh is 00:00 UTC, so 20:15 UTC is 3h 45m away in any zone
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 20, 15)) == RefreshCountdown(hours: 3, minutes: 45))
        // a partial minute rounds up
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 18, 47, 30)) == RefreshCountdown(hours: 5, minutes: 13))
    }

    @Test func countdownAroundMidnight() {
        // just before midnight it never reads zero
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 23, 59, 59, millis: 999)) == RefreshCountdown(hours: 0, minutes: 1))
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 23, 59)) == RefreshCountdown(hours: 0, minutes: 1))
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 4, 23, 58, 59, millis: 999)) == RefreshCountdown(hours: 0, minutes: 2))
        // at and just after midnight it rolls over to the next day's refresh
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 5)) == RefreshCountdown(hours: 24, minutes: 0))
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 5, 0, 0, 0, millis: 1)) == RefreshCountdown(hours: 24, minutes: 0))
        #expect(freeRefreshCountdown(now: Self.utc(2026, 10, 5, 0, 1)) == RefreshCountdown(hours: 23, minutes: 59))
    }

    @Test func countdownChangesOnlyAtWallClockMinutes() {
        // so a TimelineView(.everyMinute) is enough to keep it current
        let minuteStart = Self.utc(2026, 10, 4, 18, 47)
        let countdown = freeRefreshCountdown(now: minuteStart.addingTimeInterval(0.001))
        #expect(freeRefreshCountdown(now: minuteStart.addingTimeInterval(59.999)) == countdown)
        #expect(freeRefreshCountdown(now: minuteStart.addingTimeInterval(60)) != countdown)
    }

    @Test func countdownLabelIsACompactDuration() {
        #expect(freeRefreshCountdownLabel(now: Self.utc(2026, 10, 4, 18, 48)) == "5h 12m")
        #expect(freeRefreshCountdownLabel(now: Self.utc(2026, 10, 4, 23)) == "1h 0m")
        #expect(freeRefreshCountdownLabel(now: Self.utc(2026, 10, 4, 23, 1)) == "59m")
        #expect(freeRefreshCountdownLabel(now: Self.utc(2026, 10, 4, 23, 59, 59, millis: 999)) == "1m")
        #expect(freeRefreshCountdownLabel(now: Self.utc(2026, 10, 5)) == "24h 0m")
    }

    // MARK: the amounts

    @Test func usedIsWhatIsNeitherAvailableNorPending() {
        let info = dataInfo(
            startBalanceByteCount: 30 * Self.gib,
            availableByteCount: 20 * Self.gib,
            pendingByteCount: 2 * Self.gib,
            formatBytes: { "\($0 / Self.gib)" }
        )
        #expect(info == DataInfo(used: "8", pending: "2", available: "20", daily: "30"))
    }

    @Test func usedNeverGoesNegative() {
        // the server samples the values independently
        let info = dataInfo(
            startBalanceByteCount: Self.gib,
            availableByteCount: Self.gib,
            pendingByteCount: Self.gib / 2,
            formatBytes: { "\($0)" }
        )
        #expect(info.used == "0")
        #expect(info.pending == "\(Self.gib / 2)")
        let negative = dataInfo(startBalanceByteCount: 0, availableByteCount: -1, pendingByteCount: -1, formatBytes: { "\($0)" })
        #expect(negative == DataInfo(used: "0", pending: "0", available: "0", daily: "0"))
    }

    @Test func allPendingNothingAvailable() {
        // the reported case: Pending fills the bar and nothing is available
        let info = dataInfo(
            startBalanceByteCount: 30 * Self.gib,
            availableByteCount: 0,
            pendingByteCount: 29 * Self.gib,
            formatBytes: { "\($0 / Self.gib)" }
        )
        #expect(info == DataInfo(used: "1", pending: "29", available: "0", daily: "30"))
    }

    @Test func amountsUseTheUsageBarFormat() {
        let info = dataInfo(startBalanceByteCount: 30 * Self.gib, availableByteCount: 20 * Self.gib, pendingByteCount: Self.gib / 2)
        #expect(info.used == formatBalanceBytes(30 * Self.gib - 20 * Self.gib - Self.gib / 2))
        #expect(info.pending == formatBalanceBytes(Self.gib / 2))
        #expect(info.available == formatBalanceBytes(20 * Self.gib))
        #expect(info.daily == formatBalanceBytes(30 * Self.gib))
    }

    @Test func dailyAmountIsTheServersStartBalance() {
        // never a hard-coded allowance: whatever start_balance_byte_count says
        for start in [30 * Self.gib, 60 * Self.gib, 33 * Self.gib, 10 * Self.tib, 12_345_678_901] {
            #expect(dataInfo(startBalanceByteCount: start, availableByteCount: 0, pendingByteCount: 0).daily == formatBalanceBytes(start))
        }
        #expect(dataInfo(startBalanceByteCount: 60 * Self.gib, availableByteCount: 0, pendingByteCount: 0, formatBytes: { "\($0 / Self.gib)" }).daily == "60")
    }

    // MARK: when each entry point shows

    @Test func freeRefreshLineIsForNetworksWithoutPro() {
        #expect(dataInfoShowsFreeRefresh(isPro: false))
        #expect(!dataInfoShowsFreeRefresh(isPro: true))
    }

    @Test func outOfBalanceNoticeLeadsWithTheRefreshWheneverTheGateHolds() {
        for status in [ConnectionStatus.connecting, .destinationSet, .connected, .disconnected] {
            let buttons = connectActionButtons(gateActive: true, connectionStatus: status, displayReconnectTunnel: false)
            #expect(outOfBalanceNotice(buttons: buttons) == OutOfBalanceNotice(refresh: true, held: true), "\(status)")
        }
        let held = connectActionButtons(gateActive: true, connectionStatus: nil, displayReconnectTunnel: false)
        #expect(outOfBalanceNotice(buttons: held) == OutOfBalanceNotice(refresh: true, held: true))
    }

    @Test func noOutOfBalanceNoticeOutsideTheGate() {
        for status in [ConnectionStatus.connecting, .destinationSet, .connected, .disconnected] {
            for reconnect in [false, true] {
                let buttons = connectActionButtons(gateActive: false, connectionStatus: status, displayReconnectTunnel: reconnect)
                #expect(outOfBalanceNotice(buttons: buttons) == OutOfBalanceNotice(refresh: false, held: false), "\(status)")
            }
        }
        // a supporter or a balance poll never holds the gate
        #expect(!insufficientBalanceGateActive(insufficientBalance: true, plan: .supporter, isPollingSubscriptionBalance: false))
        #expect(!insufficientBalanceGateActive(insufficientBalance: true, plan: .none, isPollingSubscriptionBalance: true))
    }

    @Test func upgradeShowsTheRefreshOnlyWhenABlockedConnectOpenedIt() {
        #expect(upgradeShowsFreeRefresh(openedByStartConnectBlock: true, isPro: false))
        // Get Pro, the onboarding links, a legacy guest's purchase
        #expect(!upgradeShowsFreeRefresh(openedByStartConnectBlock: false, isPro: false))
        // Pro gets no free daily grant
        #expect(!upgradeShowsFreeRefresh(openedByStartConnectBlock: true, isPro: true))
    }
}
