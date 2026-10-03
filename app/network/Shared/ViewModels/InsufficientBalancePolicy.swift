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

import Foundation

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
