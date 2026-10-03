import Foundation
import Testing
@testable import URnetwork

/// The insufficient balance state must hold traffic in the tunnel, tell the
/// user once, and always leave an explicit disconnect in reach, never
/// disconnecting on its own (urnetwork/android#483). Every input is passed in:
/// no clock, timer or device state is involved.
struct InsufficientBalancePolicyTests {

    private static let requestedStatuses: [ConnectionStatus] = [.connecting, .destinationSet, .connected]

    // MARK: explicit disconnect

    @Test func gateOffersDisconnectNextToUpgradeForEveryRequestedStatus() {
        for status in Self.requestedStatuses {
            for displayReconnectTunnel in [false, true] {
                let buttons = connectActionButtons(
                    gateActive: true,
                    connectionStatus: status,
                    displayReconnectTunnel: displayReconnectTunnel
                )
                #expect(
                    buttons == ConnectActionButtons(upgrade: true, disconnect: true),
                    "gate hides disconnect for \(status) reconnect=\(displayReconnectTunnel)"
                )
            }
        }
    }

    @Test func gateShowsOnlyUpgradeWhenNothingIsRequested() {
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

    @Test func gateHoldsOnlyForAnOutOfBalanceNonSupporterNotPolling() {
        #expect(insufficientBalanceGateActive(insufficientBalance: true, plan: .none, isPollingSubscriptionBalance: false))
        #expect(!insufficientBalanceGateActive(insufficientBalance: true, plan: .supporter, isPollingSubscriptionBalance: false))
        #expect(!insufficientBalanceGateActive(insufficientBalance: true, plan: .none, isPollingSubscriptionBalance: true))
        #expect(!insufficientBalanceGateActive(insufficientBalance: false, plan: .none, isPollingSubscriptionBalance: false))
    }

    // MARK: no automatic disconnect

    @Test func contractReactionNeverDisconnects() {
        var disconnects = 0
        let reaction = InsufficientBalanceContractReaction(disconnect: { disconnects += 1 }, notice: { _ in })
        let statuses: [ConnectionStatus?] = Self.requestedStatuses + [.disconnected, nil]
        for status in statuses {
            for isSupporter in [false, true] {
                for isPolling in [false, true] {
                    reaction.update(insufficientBalance: true, isSupporter: isSupporter, isPolling: isPolling, connectionStatus: status)
                    reaction.update(insufficientBalance: false, isSupporter: isSupporter, isPolling: isPolling, connectionStatus: status)
                    reaction.update(insufficientBalance: true, isSupporter: isSupporter, isPolling: isPolling, connectionStatus: status)
                }
            }
        }
        reaction.reset()
        #expect(disconnects == 0, "out of balance disconnected \(disconnects) times")
    }

    // MARK: held-traffic notice

    private static func noticeActions(_ steps: [(insufficient: Bool, supporter: Bool, polling: Bool)]) -> [InsufficientBalanceNoticeAction] {
        var actions: [InsufficientBalanceNoticeAction] = []
        let reaction = InsufficientBalanceContractReaction(disconnect: {}, notice: { actions.append($0) })
        for step in steps {
            reaction.update(insufficientBalance: step.insufficient, isSupporter: step.supporter, isPolling: step.polling, connectionStatus: .connected)
        }
        return actions
    }

    @Test func noticePostsOnceWhenTheGateIsEntered() {
        let actions = Self.noticeActions([
            (false, false, false),
            (true, false, false),
            (true, false, false),
            (true, false, false),
        ])
        #expect(actions == [.post])
    }

    @Test func noticeIsNotRepeatedWhenTheGateFlapsWithinAnEpisode() {
        // a poll starting and ending inside the episode does not re-post
        let actions = Self.noticeActions([
            (true, false, false),
            (true, false, true),
            (true, false, false),
        ])
        #expect(actions == [.post])
    }

    @Test func noticeIsRemovedAndReArmsAfterTheEpisodeEnds() {
        let actions = Self.noticeActions([
            (true, false, false),
            (false, false, false),
            (true, false, false),
        ])
        #expect(actions == [.post, .remove, .post])
    }

    @Test func noticeNeverForSupporterOrWhilePolling() {
        #expect(Self.noticeActions([(true, true, false), (true, true, false), (false, true, false)]).isEmpty)
        #expect(Self.noticeActions([(true, false, true), (true, false, true), (false, false, true)]).isEmpty)
    }

    @Test func pollingAtEntryDefersTheNoticeUntilTheGateHolds() {
        let actions = Self.noticeActions([
            (true, false, true),
            (true, false, false),
            (true, false, false),
        ])
        #expect(actions == [.post])
    }

    // MARK: capture held

    /// Balance is not an input of the tunnel lifetime rule: a requested
    /// connect keeps the tunnel up, so out of balance traffic stays captured
    /// until the user disconnects.
    @Test func connectRequestedKeepsTheTunnelUp() {
        for provideEnabled in [false, true] {
            for routeLocal in [false, true] {
                for providePaused in [false, true] {
                    let state = VPNDesiredState(
                        provideEnabled: provideEnabled,
                        connectEnabled: true,
                        routeLocal: routeLocal,
                        providePaused: providePaused
                    )
                    #expect(state.shouldRun)
                }
            }
        }
        // after the user disconnects, only provide or the kill switch keep it
        #expect(!VPNDesiredState(provideEnabled: false, connectEnabled: false, routeLocal: true, providePaused: false).shouldRun)
        #expect(VPNDesiredState(provideEnabled: false, connectEnabled: false, routeLocal: false, providePaused: false).shouldRun)
    }
}
