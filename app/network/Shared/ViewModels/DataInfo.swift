//
//  DataInfo.swift
//  URnetwork
//

import Foundation

/**
 * The "About your data" sheet, kept pure so it is unit testable.
 *
 * The sheet explains the usage bar: Used, Pending (balance held by open
 * connections, returned when they close) and Available, the daily balance the
 * server reports (`start_balance_byte_count`, never a hard-coded amount), and
 * when the free data refreshes. The server grants the free daily balance at
 * 00:00 UTC to every network without Pro (RefreshFreeTransferBalances), so the
 * refresh is computed on the device as the next UTC midnight.
 *
 * It opens from the info button next to the daily balance in the usage bar
 * and from the Why? link in the out-of-balance notice.
 */

private let freeRefreshDay: TimeInterval = 24 * 60 * 60

/// The next free data refresh: the first 00:00 UTC strictly after `now`.
/// Epoch time has no leap seconds, so UTC days are whole multiples of a day.
func nextFreeRefresh(after now: Date) -> Date {
    let day = (now.timeIntervalSince1970 / freeRefreshDay).rounded(.down)
    return Date(timeIntervalSince1970: (day + 1) * freeRefreshDay)
}

struct RefreshCountdown: Equatable {
    var hours: Int
    var minutes: Int
}

/// The time left until the next free data refresh, rounded up to whole
/// minutes so it never reads zero while the refresh is still ahead. It changes
/// at the start of a wall-clock minute, so a `.everyMinute` timeline keeps it
/// current.
func freeRefreshCountdown(now: Date) -> RefreshCountdown {
    let remaining = nextFreeRefresh(after: now).timeIntervalSince(now)
    let totalMinutes = Int((remaining / 60).rounded(.up))
    return RefreshCountdown(hours: totalMinutes / 60, minutes: totalMinutes % 60)
}

/// The countdown as a compact duration ("5h 12m", or "12m" in the last
/// hour), with the provider connected duration strings.
func freeRefreshCountdownLabel(now: Date) -> String {
    let countdown = freeRefreshCountdown(now: now)
    if 0 < countdown.hours {
        return String(format: String(localized: "%1$lldh %2$lldm"), countdown.hours, countdown.minutes)
    }
    return String(format: String(localized: "%lldm"), countdown.minutes)
}

struct DataInfo: Equatable {
    var used: String
    var pending: String
    var available: String
    var daily: String
}

/// The sheet's amounts from the balance, split the way the usage bar splits
/// it: used is start - available - pending, clamped at 0 (the server samples
/// the values independently, so the raw difference can go negative).
func dataInfo(
    startBalanceByteCount: Int,
    availableByteCount: Int,
    pendingByteCount: Int,
    formatBytes: (Int) -> String = formatBalanceBytes
) -> DataInfo {
    let available = max(0, availableByteCount)
    let pending = max(0, pendingByteCount)
    let start = max(0, startBalanceByteCount)
    let used = max(0, start - available - pending)
    return DataInfo(
        used: formatBytes(used),
        pending: formatBytes(pending),
        available: formatBytes(available),
        daily: formatBytes(start)
    )
}

/// Whether the sheet says when the free data refreshes. Pro networks get the
/// Pro grant instead of the free daily one, so the line would not apply.
func dataInfoShowsFreeRefresh(isPro: Bool) -> Bool {
    !isPro
}

struct OutOfBalanceNotice: Equatable {
    /// "Free data refreshes in {time}." with a Why? link to the data sheet.
    var refresh: Bool
    /// Traffic is held in the tunnel until the user upgrades or disconnects.
    var held: Bool
    /// "{amount} is reserved ..." or "You're out of data ...", or neither.
    var kind: OutOfBalanceKind = .unknown
    /// "You'll be reconnected when data is available again."
    var willReconnect: Bool = false
    /// Cancel next to it: a refused start has no Disconnect to stop it.
    var cancel: Bool = false
}

/// The notice above the drawer's out-of-balance buttons. It leads with when
/// the free data refreshes, so the upgrade button does not read as the only
/// way back; Why? opens the "About your data" sheet. Then whether the data is
/// reserved or used up (BalanceRecovery.swift), and the held-traffic line,
/// shown whenever the gate holds as before.
///
/// While a connect the user asked for waits on the balance (`recovery`, nil
/// when there is none), it says the app reconnects by itself: for a held
/// connection, and for a refused start even outside the gate, since that
/// start can still fire. A refused start gets Cancel, the only way to stop it.
func outOfBalanceNotice(
    buttons: ConnectActionButtons,
    kind: OutOfBalanceKind = .unknown,
    recovery: BalanceRecoveryState? = nil
) -> OutOfBalanceNotice {
    let startWaiting = recovery?.startWaiting == true
    let willReconnect = recovery?.retriesLeft == true
        && (startWaiting || (buttons.upgrade && buttons.disconnect))
    return OutOfBalanceNotice(
        refresh: buttons.upgrade,
        held: buttons.upgrade,
        kind: buttons.upgrade ? kind : .unknown,
        willReconnect: willReconnect,
        cancel: willReconnect && startWaiting
    )
}

/// Whether the upgrade sheet leads with when the free data refreshes and
/// offers Wait for refresh: only when a start connect blocked by the balance
/// opened it (ConnectViewModel.upgradeOpenedByStartConnectBlock). Pro is never
/// blocked, and gets no free grant.
func upgradeShowsFreeRefresh(openedByStartConnectBlock: Bool, isPro: Bool) -> Bool {
    openedByStartConnectBlock && !isPro
}
