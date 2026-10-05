//
//  BalanceRecovery.swift
//  URnetwork
//
//  Why the balance is out (reserved or used up), and the self-recovery of a
//  connect insufficient balance blocked, kept pure so they are unit testable.
//  Shared by iOS and macOS; the same rules as android BalanceRecovery.kt.
//
//  A connect the user asked for is blocked in one of two ways (see
//  InsufficientBalancePolicy): a start the gate refused, which leaves the
//  tunnel down, or a requested connection held out of balance, which keeps
//  the tunnel up with no exit. Either way the balance usually comes back by
//  itself: open connections return the reserved data they do not use as they
//  close, and the free data refreshes at 00:00 UTC. So while the user waits,
//  every balance reading is fed in, and once the available balance is back at
//  `balanceRecoveryThresholdByteCount` the connect is retried: the refused
//  start is started, or the held connection is rebuilt. A rebuild asks for
//  new contracts and drops the latched contract status, which nothing else
//  clears while the held connection sends nothing.
//
//  The retry is bounded:
//  - Once per recovery. A block arms it, and so does a reading below the
//    threshold; a retry disarms it. Only a reading fetched at or after the
//    arming counts, so a balance read before the block never retries.
//  - At most `balanceRecoveryMaxRetries` in a row. A new ask from the user
//    refills them, and so does a connection that stays out of the block for
//    `balanceRecoveryBudgetReset` after a retry.
//
//  It never connects a user who did not ask to connect: only a refused start
//  (the user's own connect) or a connection already requested is retried, and
//  a disconnect, a sign out or Cancel clears the refused start (`clear`).
//

import Foundation

/// The available balance at which data counts as back for a blocked connect,
/// and the reserved balance whose return could bring it back. The server
/// grants a contract down to 1 MiB, but a connection opens several at once
/// and ramps each to 128 MiB, so a few MiB back would only block again.
let balanceRecoveryThresholdByteCount: Int64 = 64 * 1024 * 1024

/// Retries in a row before the user has to act again.
let balanceRecoveryMaxRetries = 3

/// How long a retried connection stays out of the block to refill the retries.
let balanceRecoveryBudgetReset: TimeInterval = 10 * 60

/// Why the balance is out, from the last account balance: what is missing is
/// either held by open connections, which return what they do not use as
/// they close, or used up until the free refresh or an upgrade.
enum OutOfBalanceKind: Equatable {
    /// No balance known, Pro, or the balance reads available again: say neither.
    case unknown
    /// Enough is reserved (Pending) that its return could bring data back.
    case reserved
    /// Nothing meaningful is reserved: out until the free refresh or an upgrade.
    case exhausted
}

/// Reserved or exhausted, by the same threshold the self-recovery waits for:
/// reserved when at least that much is held by open connections. No time is
/// promised for its return; connections close when they are used up or end.
func outOfBalanceKind(_ balance: WidgetBalanceSnapshot?) -> OutOfBalanceKind {
    guard let balance, !balance.isPro else {
        return .unknown
    }
    if balanceRecoveryThresholdByteCount <= balance.balanceByteCount {
        return .unknown
    }
    if balanceRecoveryThresholdByteCount <= balance.openTransferByteCount {
        return .reserved
    }
    return .exhausted
}

enum BalanceRecoveryStep<Target> {
    /// Nothing to retry now (named apart from Optional's `.none`).
    case noRetry
    /// Start the connect the gate refused, to the target the user asked for.
    case start(Target)
    /// Rebuild the held connection (connect again to its location).
    case rebuild
}

extension BalanceRecoveryStep: Equatable where Target: Equatable {}

/// What the out-of-balance notice says about the recovery.
struct BalanceRecoveryState: Equatable {
    /// A refused start is waiting for the balance (Cancel clears it).
    var startWaiting = false
    /// A retry is still allowed: "You'll be reconnected when data is available again."
    var retriesLeft = true
}

struct BalanceRecovery<Target> {
    // boxed, so a nil target (the best available provider) is still a start
    private struct RefusedStart {
        var target: Target
    }

    private let thresholdByteCount: Int64
    private let maxRetries: Int
    private let budgetReset: TimeInterval

    private var refusedStart: RefusedStart?
    private var held = false
    private var armedAt: Date?
    private var retries = 0
    private var lastRetryAt = Date.distantPast

    init(
        thresholdByteCount: Int64 = balanceRecoveryThresholdByteCount,
        maxRetries: Int = balanceRecoveryMaxRetries,
        budgetReset: TimeInterval = balanceRecoveryBudgetReset
    ) {
        self.thresholdByteCount = thresholdByteCount
        self.maxRetries = maxRetries
        self.budgetReset = budgetReset
    }

    var state: BalanceRecoveryState {
        BalanceRecoveryState(startWaiting: refusedStart != nil, retriesLeft: retries < maxRetries)
    }

    /// The gate refused a start the user asked for: wait for the balance to
    /// retry it. A new ask refills the retries.
    mutating func startRefused(_ target: Target, now: Date) {
        refusedStart = RefusedStart(target: target)
        retries = 0
        arm(now)
    }

    /// The user took the connect into their own hands (connected,
    /// disconnected, signed out or cancelled the wait): nothing is waiting
    /// any more.
    mutating func clear() {
        refusedStart = nil
        armedAt = nil
        retries = 0
    }

    /// Feeds one observation: whether the out-of-balance gate holds, whether
    /// a connection is requested, and the last balance reading (nil when none
    /// is known). Returns the retry to make now, at most one per recovery.
    mutating func observe(
        gate: Bool,
        connectRequested: Bool,
        balance: WidgetBalanceSnapshot?,
        now: Date
    ) -> BalanceRecoveryStep<Target> {
        let heldNow = gate && connectRequested
        if heldNow && !held {
            // a connection the user asked for is newly held
            arm(now)
        }
        held = heldNow
        if connectRequested && !heldNow && 0 < retries && budgetReset <= now.timeIntervalSince(lastRetryAt) {
            retries = 0
        }
        if refusedStart == nil && !heldNow {
            armedAt = nil
            return .noRetry
        }
        guard let balance else {
            return .noRetry
        }
        if balance.balanceByteCount < thresholdByteCount {
            arm(balance.updatedAt)
            return .noRetry
        }
        guard let armedAt, armedAt <= balance.updatedAt, retries < maxRetries else {
            return .noRetry
        }
        self.armedAt = nil
        retries += 1
        lastRetryAt = now
        guard let start = refusedStart else {
            return .rebuild
        }
        refusedStart = nil
        return .start(start.target)
    }

    private mutating func arm(_ at: Date) {
        if armedAt == nil {
            armedAt = at
        }
    }
}
