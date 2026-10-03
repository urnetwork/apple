import Foundation
import Testing
@testable import URnetwork

/// The insufficient balance state must never leave the user without a way to
/// release the tunnel (urnetwork/android#483).
struct InsufficientBalancePolicyTests {

    private static let requestedStatuses: [ConnectionStatus] = [.connecting, .destinationSet, .connected]

    @Test func gateHoldsOnlyForAnOutOfBalanceNonSupporterNotPolling() {
        #expect(insufficientBalanceGateActive(insufficientBalance: true, plan: .none, isPollingSubscriptionBalance: false))
        #expect(!insufficientBalanceGateActive(insufficientBalance: true, plan: .supporter, isPollingSubscriptionBalance: false))
        #expect(!insufficientBalanceGateActive(insufficientBalance: true, plan: .none, isPollingSubscriptionBalance: true))
        #expect(!insufficientBalanceGateActive(insufficientBalance: false, plan: .none, isPollingSubscriptionBalance: false))
    }

    @Test func gateOffersDisconnectNextToUpgradeWhileAConnectIsRequested() {
        for status in Self.requestedStatuses {
            for displayReconnectTunnel in [false, true] {
                let buttons = connectActionButtons(
                    gateActive: true,
                    connectionStatus: status,
                    displayReconnectTunnel: displayReconnectTunnel
                )
                #expect(buttons == ConnectActionButtons(upgrade: true, disconnect: true), "status \(status)")
            }
        }
    }

    @Test func gateShowsOnlyUpgradeWhenDisconnected() {
        for status in [ConnectionStatus.disconnected, nil] {
            let buttons = connectActionButtons(gateActive: true, connectionStatus: status, displayReconnectTunnel: false)
            #expect(buttons == ConnectActionButtons(upgrade: true))
        }
    }

    @Test func outsideTheGateTheActionsAreUnchanged() {
        #expect(connectActionButtons(gateActive: false, connectionStatus: .disconnected, displayReconnectTunnel: false)
            == ConnectActionButtons(connect: true))
        #expect(connectActionButtons(gateActive: false, connectionStatus: .connected, displayReconnectTunnel: false)
            == ConnectActionButtons(disconnect: true))
        #expect(connectActionButtons(gateActive: false, connectionStatus: .connected, displayReconnectTunnel: true)
            == ConnectActionButtons(reconnect: true))
        #expect(connectActionButtons(gateActive: false, connectionStatus: nil, displayReconnectTunnel: false)
            == ConnectActionButtons(disconnect: true))
    }

    @Test func roundButtonDisconnectsInTheGate() {
        for status in Self.requestedStatuses {
            let action = connectButtonTapAction(
                connectionStatus: status,
                insufficientBalance: true,
                plan: .none,
                isPollingSubscriptionBalance: false,
                countsConnectedTaps: status == .connected
            )
            #expect(action == .disconnect, "status \(status)")
        }
    }

    @Test func roundButtonKeepsItsBehaviorOutsideTheGate() {
        #expect(connectButtonTapAction(connectionStatus: .disconnected, insufficientBalance: false, plan: .none,
                                       isPollingSubscriptionBalance: false, countsConnectedTaps: false) == .connect)
        #expect(connectButtonTapAction(connectionStatus: .disconnected, insufficientBalance: true, plan: .supporter,
                                       isPollingSubscriptionBalance: false, countsConnectedTaps: false) == .connect)
        // out of balance and disconnected: no connect, as before
        #expect(connectButtonTapAction(connectionStatus: .disconnected, insufficientBalance: true, plan: .none,
                                       isPollingSubscriptionBalance: false, countsConnectedTaps: false) == .none)
        #expect(connectButtonTapAction(connectionStatus: .connected, insufficientBalance: false, plan: .none,
                                       isPollingSubscriptionBalance: false, countsConnectedTaps: true) == .countConnectedTap)
        #expect(connectButtonTapAction(connectionStatus: .connected, insufficientBalance: true, plan: .supporter,
                                       isPollingSubscriptionBalance: false, countsConnectedTaps: true) == .countConnectedTap)
        #expect(connectButtonTapAction(connectionStatus: .connecting, insufficientBalance: true, plan: .none,
                                       isPollingSubscriptionBalance: true, countsConnectedTaps: false) == .none)
    }

    @Test func autoDisconnectWaitsForTheGrace() {
        let grace = insufficientBalanceAutoDisconnectGrace
        #expect(10 <= grace && grace <= 30)
        for status in Self.requestedStatuses {
            #expect(!insufficientBalanceShouldAutoDisconnect(gateActive: true, gateHeldFor: 0, killSwitch: false, connectionStatus: status))
            #expect(!insufficientBalanceShouldAutoDisconnect(gateActive: true, gateHeldFor: grace - 1, killSwitch: false, connectionStatus: status))
            #expect(insufficientBalanceShouldAutoDisconnect(gateActive: true, gateHeldFor: grace, killSwitch: false, connectionStatus: status))
        }
    }

    @Test func autoDisconnectNeverForSupporterOrWhilePolling() {
        let held = insufficientBalanceAutoDisconnectGrace * 4
        for (plan, polling) in [(Plan.supporter, false), (Plan.none, true), (Plan.supporter, true)] {
            let gateActive = insufficientBalanceGateActive(insufficientBalance: true, plan: plan, isPollingSubscriptionBalance: polling)
            #expect(!insufficientBalanceShouldAutoDisconnect(gateActive: gateActive, gateHeldFor: held, killSwitch: false, connectionStatus: .connected))
        }
    }

    @Test func autoDisconnectKeepsCaptureWithTheKillSwitch() {
        let held = insufficientBalanceAutoDisconnectGrace * 4
        #expect(!insufficientBalanceShouldAutoDisconnect(gateActive: true, gateHeldFor: held, killSwitch: true, connectionStatus: .connected))
        // the disconnect button is still offered
        #expect(connectActionButtons(gateActive: true, connectionStatus: .connected, displayReconnectTunnel: false).disconnect)
    }

    @Test func autoDisconnectOnlyWhileAConnectIsRequested() {
        let held = insufficientBalanceAutoDisconnectGrace * 4
        #expect(!insufficientBalanceShouldAutoDisconnect(gateActive: true, gateHeldFor: held, killSwitch: false, connectionStatus: .disconnected))
        #expect(!insufficientBalanceShouldAutoDisconnect(gateActive: true, gateHeldFor: held, killSwitch: false, connectionStatus: nil))
    }
}
