//
//  InsufficientBalancePolicy.swift
//  URnetwork
//
//  Pure decisions for the insufficient balance state, shared by the connect
//  actions, the connect button and the auto-disconnect in ConnectViewModel.
//  Insufficient balance is a billing state, not a dropped tunnel: the user
//  must always have a way to disconnect, and a balance that stays
//  insufficient releases the connect request instead of holding traffic in a
//  tunnel with no exit (Android parity, urnetwork/android#483).
//

import Foundation

/// How long the gate must hold before the connect request is released. The
/// contract status can latch insufficient balance briefly (a backend
/// incident, a balance top-up in flight), so a short grace rides that out.
let insufficientBalanceAutoDisconnectGrace: TimeInterval = 15

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
/// disconnect stays whenever a connect is requested, so the user is never
/// left without a way to release the tunnel. Outside the gate the rules are
/// unchanged (a nil status shows disconnect, as before).
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

/// What a tap on the round connect button does.
enum ConnectButtonTapAction: Equatable {
    case connect
    case disconnect
    case countConnectedTap
    case none
}

/// Connect while disconnected with balance (unchanged). In the gate the
/// button shows the error state, so a tap while a connect is requested
/// disconnects; otherwise a connected tap feeds the pro tap gate.
func connectButtonTapAction(
    connectionStatus: ConnectionStatus?,
    insufficientBalance: Bool,
    plan: Plan,
    isPollingSubscriptionBalance: Bool,
    countsConnectedTaps: Bool
) -> ConnectButtonTapAction {
    if connectionStatus == .disconnected
        && (!insufficientBalance || plan == .supporter)
        && !isPollingSubscriptionBalance {
        return .connect
    }
    let gateActive = insufficientBalanceGateActive(
        insufficientBalance: insufficientBalance,
        plan: plan,
        isPollingSubscriptionBalance: isPollingSubscriptionBalance
    )
    if gateActive && connectionStatus != nil && connectionStatus != .disconnected {
        return .disconnect
    }
    if countsConnectedTaps {
        return .countConnectedTap
    }
    return .none
}

/// Whether to release the connect request. Only once the gate has held for
/// the full grace, only while a connect is requested, and never with the kill
/// switch on: the user asked to fail closed, so capture is kept and the
/// disconnect button stays offered instead.
func insufficientBalanceShouldAutoDisconnect(
    gateActive: Bool,
    gateHeldFor: TimeInterval,
    killSwitch: Bool,
    connectionStatus: ConnectionStatus?
) -> Bool {
    gateActive
        && insufficientBalanceAutoDisconnectGrace <= gateHeldFor
        && !killSwitch
        && connectionStatus != nil
        && connectionStatus != .disconnected
}
