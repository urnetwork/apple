//
//  InsufficientBalancePolicy.swift
//  URnetwork
//
//  Pure decisions for the insufficient balance state, shared by iOS and
//  macOS (urnetwork/android#483). Insufficient balance never disconnects on
//  its own: dropping the connect request could release traffic outside the
//  tunnel without the user knowing. Instead the tunnel keeps holding traffic,
//  the user is told once per out of balance episode, and an explicit
//  disconnect stays in reach next to the upgrade button.
//
//  A connect the user does not have yet is different: starting one out of
//  balance is blocked at every entry point (the connect view, the macOS menu
//  bar, Shortcuts and Siri, the Control Center control, the widget), which
//  show the upgrade path instead. Only a start is gated; a connection that
//  already exists is never dropped or refused because of balance.
//
//  A start is decided on the account balance fetched in the last minute: the
//  contract status is empty until a connection is requested and is reset
//  with every destination change, so it cannot see an empty account from
//  the disconnected state. An older balance is fetched again first, and a
//  failed fetch does not block. The widget extension cannot fetch, so it
//  blocks only on a fresh App Group balance.
//
//  Foundation only: compiled into the app and the widget extension (which
//  runs without the SDK), so every surface applies the same decision.
//

import Foundation

enum ConnectionStatus: String {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case destinationSet = "DESTINATION_SET"
    case connected = "CONNECTED"
}

enum Plan: String {
    case supporter = "supporter"
    case none = "none"
}

/// The upgrade gate: out of balance, not a supporter, and not waiting on a
/// subscription balance poll that may clear it.
func insufficientBalanceGateActive(
    insufficientBalance: Bool,
    plan: Plan,
    isPollingSubscriptionBalance: Bool
) -> Bool {
    insufficientBalance && plan != .supporter && !isPollingSubscriptionBalance
}

/// Which buttons the connect actions block shows.
struct ConnectActionButtons: Equatable {
    var upgrade: Bool = false
    var connect: Bool = false
    var disconnect: Bool = false
    var reconnect: Bool = false
}

/// In the gate the upgrade button replaces connect and reconnect, but
/// disconnect stays whenever a connect is requested, so the user can always
/// release the tunnel. Outside the gate the rules are unchanged (a nil status
/// shows disconnect, as before).
func connectActionButtons(
    gateActive: Bool,
    connectionStatus: ConnectionStatus?,
    displayReconnectTunnel: Bool
) -> ConnectActionButtons {
    if gateActive {
        return ConnectActionButtons(
            upgrade: true,
            disconnect: connectionStatus != nil && connectionStatus != .disconnected
        )
    }
    return ConnectActionButtons(
        connect: connectionStatus == .disconnected,
        disconnect: connectionStatus != .disconnected && !displayReconnectTunnel,
        reconnect: displayReconnectTunnel
    )
}

enum InsufficientBalanceNoticeAction: Equatable {
    case none
    // post the held-traffic notice
    case post
    // the episode ended: withdraw the delivered notice
    case remove
}

/// Decides the held-traffic notice once per out of balance episode. An
/// episode starts when insufficient balance turns on and ends only when it
/// turns off. The notice posts the first time the gate holds within the
/// episode, so a supporter or a polling balance at entry suppresses it until
/// the gate actually holds, and it never posts again until the episode ends.
struct InsufficientBalanceNoticeTracker {
    private var inEpisode = false
    private var posted = false

    mutating func update(insufficientBalance: Bool, isSupporter: Bool, isPolling: Bool) -> InsufficientBalanceNoticeAction {
        guard insufficientBalance else {
            let wasPosted = posted
            inEpisode = false
            posted = false
            return wasPosted ? .remove : .none
        }
        inEpisode = true
        if !posted && !isSupporter && !isPolling {
            posted = true
            return .post
        }
        return .none
    }
}

/// The view model's reaction to a contract status or guard change, kept
/// apart from SwiftUI so it can be driven deterministically. It is handed
/// the disconnect path only so a test can prove it is never taken: out of
/// balance holds traffic in the tunnel until the user disconnects.
final class InsufficientBalanceContractReaction {
    private var tracker = InsufficientBalanceNoticeTracker()
    private let disconnect: () -> Void
    private let notice: (InsufficientBalanceNoticeAction) -> Void

    init(disconnect: @escaping () -> Void, notice: @escaping (InsufficientBalanceNoticeAction) -> Void) {
        self.disconnect = disconnect
        self.notice = notice
    }

    func update(
        insufficientBalance: Bool,
        isSupporter: Bool,
        isPolling: Bool,
        connectionStatus: ConnectionStatus?
    ) {
        let action = tracker.update(
            insufficientBalance: insufficientBalance,
            isSupporter: isSupporter,
            isPolling: isPolling
        )
        if action != .none {
            notice(action)
        }
    }

    /// Ends any episode (sign out, account switch) and withdraws its notice.
    func reset() {
        update(insufficientBalance: false, isSupporter: false, isPolling: false, connectionStatus: nil)
    }
}

// MARK: start connect vs already connected

/// What a connect entry point asks for. A start brings up a connection the
/// user does not have. Already connected keeps or adjusts one the user never
/// left: a location change or reconnect while a connect is requested, the
/// system restarting the tunnel (on demand after a network change, sleep,
/// boot, a provider restart), the app relaunching into its saved connect
/// location, or reconnecting after the macOS purchase flow dropped it.
enum ConnectAttempt: Equatable {
    case start
    case alreadyConnected
}

enum ConnectAttemptDecision: Equatable {
    case connect
    // do not start the tunnel; show the upgrade path
    case upgrade
}

/// Nothing requested (or not yet known) means a connect would be a start.
func connectAttempt(connectionStatus: ConnectionStatus?) -> ConnectAttempt {
    connectionStatus == nil || connectionStatus == .disconnected ? .start : .alreadyConnected
}

/// A start is judged on a balance fetched at most this long ago. An older one
/// is fetched again first: a balance from before a purchase, a top up or a
/// refill must not send a funded account to upgrade.
let startConnectBalanceMaxAge: TimeInterval = 60
/// The fetch before a start is bounded; a slow or failed fetch does not block
/// (the server refuses the contract anyway, and a held connection tells the
/// user).
let startConnectBalanceFetchTimeout: TimeInterval = 5

/// Nothing left on the account: none available and none held in open
/// contracts (which return what they do not use). Pro is never exhausted,
/// and an unknown balance never is.
func accountBalanceExhausted(_ balance: WidgetBalanceSnapshot?) -> Bool {
    guard let balance else {
        return false
    }
    return !balance.isPro && balance.balanceByteCount <= 0 && balance.openTransferByteCount <= 0
}

/// The balance if it was fetched within `startConnectBalanceMaxAge` of `now`.
/// One stamped after `now` (the clock moved back) is not trusted either.
func freshStartConnectBalance(_ balance: WidgetBalanceSnapshot?, now: Date) -> WidgetBalanceSnapshot? {
    guard let balance else {
        return nil
    }
    let age = now.timeIntervalSince(balance.updatedAt)
    return 0 <= age && age <= startConnectBalanceMaxAge ? balance : nil
}

/// The gate inputs a start is decided on, other than the account balance.
/// The contract status reports insufficient balance only while a connection
/// is requested (the SDK resets it with every destination change, the user's
/// disconnect included), so a start from the disconnected state is decided by
/// the account balance.
struct StartConnectGuards: Equatable {
    var contractInsufficientBalance: Bool = false
    var isSupporter: Bool = false
    var isPollingSubscriptionBalance: Bool = false
}

/// The decision over a balance already known to be fresh, or nil when there
/// is none (never fetched, or the fetch failed): an unknown balance never
/// blocks. Only a start is ever refused.
func startConnectDecision(
    _ attempt: ConnectAttempt,
    guards: StartConnectGuards,
    balance: WidgetBalanceSnapshot?
) -> ConnectAttemptDecision {
    guard attempt == .start else {
        return .connect
    }
    let gateActive = insufficientBalanceGateActive(
        insufficientBalance: guards.contractInsufficientBalance || accountBalanceExhausted(balance),
        plan: guards.isSupporter || balance?.isPro == true ? .supporter : .none,
        isPollingSubscriptionBalance: guards.isPollingSubscriptionBalance
    )
    return gateActive ? .upgrade : .connect
}

/// The decision when it does not need a fetch: an existing connection, a
/// supporter, a running poll, a contract that already reports insufficient
/// balance, or a fresh cached balance. Nil means fetch the balance first and
/// decide with `startConnectDecision`.
func immediateStartConnectDecision(
    _ attempt: ConnectAttempt,
    guards: StartConnectGuards,
    cachedBalance: WidgetBalanceSnapshot?,
    now: Date
) -> ConnectAttemptDecision? {
    let balanceDecides = attempt == .start
        && !guards.isSupporter
        && !guards.isPollingSubscriptionBalance
        && !guards.contractInsufficientBalance
    guard balanceDecides else {
        return startConnectDecision(attempt, guards: guards, balance: nil)
    }
    guard let balance = freshStartConnectBalance(cachedBalance, now: now) else {
        return nil
    }
    return startConnectDecision(attempt, guards: guards, balance: balance)
}

/// The whole start connect decision: the cached balance when fresh, otherwise
/// the result of `fetchBalance` (nil when it fails or times out).
func resolveStartConnect(
    _ attempt: ConnectAttempt,
    guards: StartConnectGuards,
    cachedBalance: WidgetBalanceSnapshot?,
    now: Date,
    fetchBalance: () async -> WidgetBalanceSnapshot?
) async -> ConnectAttemptDecision {
    if let decision = immediateStartConnectDecision(attempt, guards: guards, cachedBalance: cachedBalance, now: now) {
        return decision
    }
    return startConnectDecision(attempt, guards: guards, balance: await fetchBalance())
}

/// The quick connect toggle (the Control Center control, the widget), which
/// runs in the widget extension without the SDK and so cannot fetch: turning
/// it on with no tunnel up is a start decided on the App Group balance when
/// fresh, and allowed when it is not. With the tunnel up (or coming up) it is
/// already connected, and off always proceeds.
func quickConnectDecision(
    on: Bool,
    tunnelActive: Bool,
    cachedBalance: WidgetBalanceSnapshot?,
    now: Date
) -> ConnectAttemptDecision {
    guard on else {
        return .connect
    }
    return immediateStartConnectDecision(
        tunnelActive ? .alreadyConnected : .start,
        guards: StartConnectGuards(),
        cachedBalance: cachedBalance,
        now: now
    ) ?? .connect
}
