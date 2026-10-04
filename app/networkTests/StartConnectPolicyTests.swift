import Foundation
import Testing
@testable import URnetwork

/// A start connect out of balance is refused, decided on a balance fetched
/// within the last minute (fetched again first when older, and allowed when
/// that fetch fails); a connection that already exists is never refused
/// (urnetwork/android#483). The clock and the fetch are passed in.
struct StartConnectPolicyTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let gib: Int64 = 1024 * 1024 * 1024

    private static func balance(
        _ balanceByteCount: Int64,
        openTransferByteCount: Int64 = 0,
        isPro: Bool = false,
        age: TimeInterval = 0
    ) -> WidgetBalanceSnapshot {
        WidgetBalanceSnapshot(
            updatedAt: now.addingTimeInterval(-age),
            startBalanceByteCount: gib,
            balanceByteCount: balanceByteCount,
            openTransferByteCount: openTransferByteCount,
            isPro: isPro
        )
    }

    /// A fake fetch that counts its calls and returns `result`.
    private final class Fetch {
        let result: WidgetBalanceSnapshot?
        private(set) var count = 0

        init(_ result: WidgetBalanceSnapshot?) {
            self.result = result
        }

        func callAsFunction() async -> WidgetBalanceSnapshot? {
            count += 1
            return result
        }
    }

    private static func resolve(
        _ attempt: ConnectAttempt = .start,
        guards: StartConnectGuards = StartConnectGuards(),
        cached: WidgetBalanceSnapshot?,
        fetch: Fetch
    ) async -> ConnectAttemptDecision {
        await resolveStartConnect(attempt, guards: guards, cachedBalance: cached, now: now, fetchBalance: { await fetch() })
    }

    // MARK: start connect

    /// A fresh start on an account that is already empty: no contract status
    /// exists yet, so only the balance can refuse it.
    @Test func freshStartOnAnEmptyAccountIsRefused() async {
        let fetch = Fetch(nil)
        #expect(await Self.resolve(cached: Self.balance(0, age: 10), fetch: fetch) == .upgrade)
        #expect(await Self.resolve(cached: Self.balance(-1, age: 0), fetch: fetch) == .upgrade)
        #expect(fetch.count == 0)
    }

    @Test func staleBalanceIsFetchedAgainBeforeAStart() async {
        // stale zero, the account was topped up since: connect
        let funded = Fetch(Self.balance(Self.gib))
        #expect(await Self.resolve(cached: Self.balance(0, age: 61), fetch: funded) == .connect)
        #expect(funded.count == 1)
        // stale and still empty: refused
        let empty = Fetch(Self.balance(0))
        #expect(await Self.resolve(cached: Self.balance(0, age: 30 * 60), fetch: empty) == .upgrade)
        #expect(empty.count == 1)
        // never fetched: fetch
        let none = Fetch(Self.balance(0))
        #expect(await Self.resolve(cached: nil, fetch: none) == .upgrade)
        #expect(none.count == 1)
    }

    /// The server refuses the contract anyway, and a held connection tells
    /// the user, so a failed fetch never blocks.
    @Test func failedFetchDoesNotBlockAStart() async {
        let failed = Fetch(nil)
        #expect(await Self.resolve(cached: Self.balance(0, age: 61), fetch: failed) == .connect)
        #expect(await Self.resolve(cached: nil, fetch: failed) == .connect)
        #expect(failed.count == 2)
    }

    @Test func balanceStampedInTheFutureIsNotTrusted() async {
        let funded = Fetch(Self.balance(Self.gib))
        #expect(await Self.resolve(cached: Self.balance(0, age: -5), fetch: funded) == .connect)
        #expect(funded.count == 1)
    }

    @Test func remainingOrOpenContractBalanceProceeds() async {
        let fetch = Fetch(nil)
        #expect(await Self.resolve(cached: Self.balance(1), fetch: fetch) == .connect)
        #expect(await Self.resolve(cached: Self.balance(0, openTransferByteCount: 1), fetch: fetch) == .connect)
        #expect(fetch.count == 0)
    }

    @Test func supporterProOrAPollNeverNeedsTheBalance() async {
        let fetch = Fetch(Self.balance(0))
        #expect(await Self.resolve(cached: Self.balance(0, isPro: true), fetch: fetch) == .connect)
        #expect(await Self.resolve(guards: StartConnectGuards(isSupporter: true), cached: nil, fetch: fetch) == .connect)
        #expect(await Self.resolve(
            guards: StartConnectGuards(contractInsufficientBalance: true, isPollingSubscriptionBalance: true),
            cached: Self.balance(0),
            fetch: fetch
        ) == .connect)
        #expect(fetch.count == 0)
    }

    @Test func contractInsufficientBalanceRefusesWithoutAFetch() async {
        let fetch = Fetch(Self.balance(Self.gib))
        #expect(await Self.resolve(
            guards: StartConnectGuards(contractInsufficientBalance: true),
            cached: nil,
            fetch: fetch
        ) == .upgrade)
        #expect(fetch.count == 0)
    }

    // MARK: already connected

    /// Running out of balance on a requested connection never refuses it: a
    /// location change, reconnect or system restart of the tunnel proceeds
    /// whatever the balance or the contract says, with no fetch.
    @Test func alreadyConnectedIsNeverRefused() async {
        let fetch = Fetch(Self.balance(0))
        for contract in [false, true] {
            for cached in [nil, Self.balance(0), Self.balance(0, age: 3600)] {
                #expect(await Self.resolve(
                    .alreadyConnected,
                    guards: StartConnectGuards(contractInsufficientBalance: contract),
                    cached: cached,
                    fetch: fetch
                ) == .connect)
            }
        }
        #expect(fetch.count == 0)
    }

    @Test func nothingRequestedIsAStartAndAnyRequestIsAlreadyConnected() {
        #expect(connectAttempt(connectionStatus: nil) == .start)
        #expect(connectAttempt(connectionStatus: .disconnected) == .start)
        for status in [ConnectionStatus.connecting, .destinationSet, .connected] {
            #expect(connectAttempt(connectionStatus: status) == .alreadyConnected)
        }
    }

    // MARK: quick connect (Control Center control, widget)

    @Test func quickConnectOnAnEmptyAccountDoesNotStartTheTunnel() {
        #expect(quickConnectDecision(on: true, tunnelActive: false, cachedBalance: Self.balance(0, age: 5), now: Self.now) == .upgrade)
    }

    /// The widget extension cannot fetch: a stale or missing balance allows
    /// the start, like a failed fetch in the app.
    @Test func quickConnectOnAStaleBalanceProceeds() {
        #expect(quickConnectDecision(on: true, tunnelActive: false, cachedBalance: Self.balance(0, age: 61), now: Self.now) == .connect)
        #expect(quickConnectDecision(on: true, tunnelActive: false, cachedBalance: nil, now: Self.now) == .connect)
    }

    @Test func quickConnectNeverRefusesARunningTunnelOrATurnOff() {
        for balanceByteCount: Int64 in [-1, 0, 1] {
            let balance = Self.balance(balanceByteCount)
            #expect(quickConnectDecision(on: true, tunnelActive: true, cachedBalance: balance, now: Self.now) == .connect)
            for tunnelActive in [false, true] {
                #expect(quickConnectDecision(on: false, tunnelActive: tunnelActive, cachedBalance: balance, now: Self.now) == .connect)
            }
        }
    }
}
