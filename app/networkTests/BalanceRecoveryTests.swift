import Foundation
import Testing
@testable import URnetwork

/// Why the balance is out (reserved by open connections or used up), and the
/// self-recovery of a connect insufficient balance blocked: the refused start
/// or the held connection is retried once the balance is back, once per
/// recovery and at most three times in a row, and never for a user who did
/// not ask to connect.
struct BalanceRecoveryTests {

    private static let gib: Int64 = 1024 * 1024 * 1024
    private static let low = balanceRecoveryThresholdByteCount - 1
    private static let back = balanceRecoveryThresholdByteCount

    fileprivate static func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + seconds)
    }

    fileprivate static func reading(_ balanceByteCount: Int64, fetchedAt seconds: TimeInterval) -> WidgetBalanceSnapshot {
        WidgetBalanceSnapshot(
            updatedAt: at(seconds),
            startBalanceByteCount: 30 * gib,
            balanceByteCount: balanceByteCount,
            openTransferByteCount: 0,
            isPro: false
        )
    }

    private static func balance(_ balanceByteCount: Int64, pending: Int64, isPro: Bool = false) -> WidgetBalanceSnapshot {
        WidgetBalanceSnapshot(
            updatedAt: at(0),
            startBalanceByteCount: 30 * gib,
            balanceByteCount: balanceByteCount,
            openTransferByteCount: pending,
            isPro: isPro
        )
    }

    // MARK: reserved or exhausted

    @Test func reservedWhenOpenConnectionsHoldEnoughToBringDataBack() {
        // the reported case: barely used, but open (or abandoned) connections
        // hold the balance as Pending
        #expect(outOfBalanceKind(Self.balance(0, pending: 30 * Self.gib)) == .reserved)
        #expect(outOfBalanceKind(Self.balance(Self.low, pending: Self.back)) == .reserved)
    }

    @Test func exhaustedWhenLittleOrNothingIsReserved() {
        #expect(outOfBalanceKind(Self.balance(0, pending: 0)) == .exhausted)
        #expect(outOfBalanceKind(Self.balance(0, pending: Self.low)) == .exhausted)
    }

    @Test func neitherWithoutAnOutOfBalanceReading() {
        #expect(outOfBalanceKind(nil) == .unknown)
        #expect(outOfBalanceKind(Self.balance(0, pending: 0, isPro: true)) == .unknown)
        // the reading says data is available: the block is about to clear
        #expect(outOfBalanceKind(Self.balance(Self.back, pending: 30 * Self.gib)) == .unknown)
    }

    // MARK: the recovery

    @Test func neverConnectsAUserWhoDidNotAsk() {
        var recovery = BalanceRecovery<String?>()
        var t: TimeInterval = 0
        for _ in 0..<5 {
            // disconnected and blocked or not: the balance runs out and comes back
            for gate in [true, false] {
                t += 60
                #expect(recovery.observeDisconnected(0, at: t, gate: gate) == .noRetry)
                t += 60
                #expect(recovery.observeDisconnected(Self.back, at: t, gate: gate) == .noRetry)
            }
            // connected and never held
            t += 60
            #expect(recovery.observe(gate: false, connectRequested: true, balance: Self.reading(Self.back, fetchedAt: t), now: Self.at(t)) == .noRetry)
        }
        #expect(!recovery.state.startWaiting)
    }

    @Test func refusedStartIsRetriedOnceWhenDataIsBack() {
        var recovery = BalanceRecovery<String?>()
        recovery.startRefused("de", now: Self.at(1))
        #expect(recovery.state.startWaiting)
        #expect(recovery.observeDisconnected(0, at: 60, gate: true) == .noRetry)
        // reserved data returned (or the free refresh)
        #expect(recovery.observeDisconnected(Self.back, at: 120) == .start("de"))
        #expect(!recovery.state.startWaiting)
        #expect(recovery.observeDisconnected(Self.back, at: 180) == .noRetry)
    }

    @Test func aBalanceReadBeforeTheBlockNeverRetries() {
        var recovery = BalanceRecovery<String?>()
        recovery.startRefused("de", now: Self.at(100))
        // the cached reading the app had before the block still says available
        #expect(recovery.observeDisconnected(Self.back, at: 40) == .noRetry)
        #expect(recovery.state.startWaiting)
        // a reading taken after the block decides
        #expect(recovery.observeDisconnected(Self.back, at: 160) == .start("de"))
    }

    @Test func heldConnectionIsRebuiltWhenReservedDataReturns() {
        var recovery = BalanceRecovery<String?>()
        #expect(recovery.observeHeld(0, at: 60) == .noRetry)
        #expect(recovery.state.retriesLeft)
        #expect(recovery.observeHeld(Self.back, at: 120) == .rebuild)
    }

    @Test func aStaleReadingAtTheStartOfAHoldDoesNotRebuild() {
        var recovery = BalanceRecovery<String?>()
        // the hold is first seen with the reading from before the balance ran out
        #expect(recovery.observe(gate: true, connectRequested: true, balance: Self.reading(Self.back, fetchedAt: 10), now: Self.at(70)) == .noRetry)
        #expect(recovery.observeHeld(0, at: 130) == .noRetry)
        #expect(recovery.observeHeld(Self.back, at: 190) == .rebuild)
    }

    @Test func oneRetryPerRecovery() {
        var recovery = BalanceRecovery<String?>()
        _ = recovery.observeHeld(0, at: 60)
        #expect(recovery.observeHeld(Self.back, at: 120) == .rebuild)
        // still blocked on later readings: no second retry until the balance
        // runs out and comes back again
        #expect(recovery.observeHeld(Self.back, at: 180) == .noRetry)
        #expect(recovery.observeHeld(Self.back, at: 240) == .noRetry)
        #expect(recovery.observeHeld(0, at: 300) == .noRetry)
        #expect(recovery.observeHeld(Self.back, at: 360) == .rebuild)
    }

    @Test func retriesAreBounded() {
        var recovery = BalanceRecovery<String?>()
        var rebuilds = 0
        var t: TimeInterval = 0
        for _ in 0..<10 {
            t += 60
            _ = recovery.observeHeld(0, at: t)
            t += 60
            if recovery.observeHeld(Self.back, at: t) == .rebuild {
                rebuilds += 1
            }
        }
        #expect(rebuilds == balanceRecoveryMaxRetries)
        #expect(!recovery.state.retriesLeft)
    }

    @Test func aNewAskRefillsTheRetries() {
        var recovery = BalanceRecovery<String?>()
        var t: TimeInterval = 0
        for _ in 0..<balanceRecoveryMaxRetries {
            t += 60
            _ = recovery.observeHeld(0, at: t)
            t += 60
            _ = recovery.observeHeld(Self.back, at: t)
        }
        #expect(!recovery.state.retriesLeft)
        t += 60
        recovery.startRefused("fr", now: Self.at(t))
        #expect(recovery.state.retriesLeft)
        t += 60
        #expect(recovery.observeHeld(Self.back, at: t) == .start("fr"))
    }

    @Test func aConnectionThatStaysUpRefillsTheRetries() {
        var recovery = BalanceRecovery<String?>()
        var t: TimeInterval = 0
        for _ in 0..<balanceRecoveryMaxRetries {
            t += 60
            _ = recovery.observeHeld(0, at: t)
            t += 60
            _ = recovery.observeHeld(Self.back, at: t)
        }
        #expect(!recovery.state.retriesLeft)
        // connected out of the block, but not for long enough yet
        let lastRetry = t
        _ = recovery.observe(gate: false, connectRequested: true, balance: Self.reading(Self.back, fetchedAt: t + 1), now: Self.at(lastRetry + 60))
        #expect(!recovery.state.retriesLeft)
        _ = recovery.observe(
            gate: false,
            connectRequested: true,
            balance: Self.reading(Self.back, fetchedAt: lastRetry + balanceRecoveryBudgetReset),
            now: Self.at(lastRetry + balanceRecoveryBudgetReset)
        )
        #expect(recovery.state.retriesLeft)
    }

    @Test func cancelAndDisconnectStopTheWait() {
        var cancelled = BalanceRecovery<String?>()
        cancelled.startRefused("de", now: Self.at(1))
        cancelled.clear()
        #expect(!cancelled.state.startWaiting)
        #expect(cancelled.observeDisconnected(0, at: 60) == .noRetry)
        #expect(cancelled.observeDisconnected(Self.back, at: 120) == .noRetry)

        // a held connection the user disconnects is not reconnected
        var disconnected = BalanceRecovery<String?>()
        _ = disconnected.observeHeld(0, at: 60)
        disconnected.clear()
        #expect(disconnected.observeDisconnected(0, at: 120, gate: true) == .noRetry)
        #expect(disconnected.observeDisconnected(Self.back, at: 180, gate: true) == .noRetry)
    }

    @Test func aHoldThatEndsByItselfIsNotRebuilt() {
        var recovery = BalanceRecovery<String?>()
        _ = recovery.observeHeld(0, at: 60)
        // the connection got contracts again on its own
        _ = recovery.observe(gate: false, connectRequested: true, balance: Self.reading(Self.back, fetchedAt: 120), now: Self.at(120))
        #expect(recovery.observe(gate: false, connectRequested: true, balance: Self.reading(Self.back, fetchedAt: 180), now: Self.at(180)) == .noRetry)
    }

    @Test func dataIsBackOnlyAtTheThreshold() {
        var recovery = BalanceRecovery<String?>()
        recovery.startRefused(nil, now: Self.at(1))
        #expect(recovery.observeDisconnected(Self.low, at: 60) == .noRetry)
        #expect(recovery.state.startWaiting)
        // a nil target (the best available provider) is still the start the user asked for
        #expect(recovery.observeDisconnected(Self.back, at: 120) == .start(nil))
    }

    @Test func anUnknownBalanceWaits() {
        var recovery = BalanceRecovery<String?>()
        recovery.startRefused("de", now: Self.at(1))
        #expect(recovery.observe(gate: true, connectRequested: false, balance: nil, now: Self.at(60)) == .noRetry)
        #expect(recovery.state.startWaiting)
    }

    @Test func theLatestRefusedStartWinsOverTheHeldConnection() {
        var recovery = BalanceRecovery<String?>()
        _ = recovery.observeHeld(0, at: 60)
        // held at one location, the user picked another and was refused
        recovery.startRefused("jp", now: Self.at(90))
        #expect(recovery.observeHeld(Self.back, at: 120) == .start("jp"))
    }
}

/// The observations the tests feed, each a reading fetched at `seconds` and
/// observed at that moment.
private extension BalanceRecovery where Target == String? {

    /// A connection the user asked for, held out of balance.
    mutating func observeHeld(_ balanceByteCount: Int64, at seconds: TimeInterval) -> BalanceRecoveryStep<String?> {
        observe(
            gate: true,
            connectRequested: true,
            balance: BalanceRecoveryTests.reading(balanceByteCount, fetchedAt: seconds),
            now: BalanceRecoveryTests.at(seconds)
        )
    }

    /// No connection requested; `gate` is whether the out-of-balance gate holds.
    mutating func observeDisconnected(_ balanceByteCount: Int64, at seconds: TimeInterval, gate: Bool = false) -> BalanceRecoveryStep<String?> {
        observe(
            gate: gate,
            connectRequested: false,
            balance: BalanceRecoveryTests.reading(balanceByteCount, fetchedAt: seconds),
            now: BalanceRecoveryTests.at(seconds)
        )
    }
}
