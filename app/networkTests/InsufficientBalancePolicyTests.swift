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
                    reaction.update(insufficientBalance: true, isSupporter: isSupporter, isPolling: isPolling, dataLimit: false, traffic: .held, connectionStatus: status)
                    reaction.update(insufficientBalance: false, isSupporter: isSupporter, isPolling: isPolling, dataLimit: false, traffic: .held, connectionStatus: status)
                    reaction.update(insufficientBalance: true, isSupporter: isSupporter, isPolling: isPolling, dataLimit: false, traffic: .held, connectionStatus: status)
                }
            }
        }
        reaction.reset()
        #expect(disconnects == 0, "out of balance disconnected \(disconnects) times")
    }

    // MARK: held-traffic notice

    private static let heldPost = InsufficientBalanceNoticeAction.post(dataLimit: false, traffic: .held)

    private static func noticeActions(_ steps: [(insufficient: Bool, supporter: Bool, polling: Bool)]) -> [InsufficientBalanceNoticeAction] {
        var actions: [InsufficientBalanceNoticeAction] = []
        let reaction = InsufficientBalanceContractReaction(disconnect: {}, notice: { actions.append($0) })
        for step in steps {
            reaction.update(insufficientBalance: step.insufficient, isSupporter: step.supporter, isPolling: step.polling, dataLimit: false, traffic: .held, connectionStatus: .connected)
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
        #expect(actions == [Self.heldPost])
    }

    @Test func noticeIsNotRepeatedWhenTheGateFlapsWithinAnEpisode() {
        // a poll starting and ending inside the episode does not re-post
        let actions = Self.noticeActions([
            (true, false, false),
            (true, false, true),
            (true, false, false),
        ])
        #expect(actions == [Self.heldPost])
    }

    @Test func noticeIsRemovedAndReArmsAfterTheEpisodeEnds() {
        let actions = Self.noticeActions([
            (true, false, false),
            (false, false, false),
            (true, false, false),
        ])
        #expect(actions == [Self.heldPost, .remove, Self.heldPost])
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
        #expect(actions == [Self.heldPost])
    }

    // MARK: what the traffic is doing while refused

    @Test func trafficIsHeldOnlyByARunningTunnel() {
        #expect(refusedTraffic(connectRequested: true, tunnelStarted: true) == .held)
        #expect(refusedTraffic(connectRequested: true, tunnelStarted: false) == .notProtected)
        #expect(refusedTraffic(connectRequested: false, tunnelStarted: true) == .none)
        #expect(refusedTraffic(connectRequested: false, tunnelStarted: false) == .none)
    }

    /// The defect: the alert told a connection with no tunnel running that its
    /// traffic was held in the tunnel, and with no connection at all.
    @Test func theAlertDoesNotClaimHeldWithNoTunnel() {
        for status in Self.requestedStatuses {
            let buttons = connectActionButtons(gateActive: true, connectionStatus: status, displayReconnectTunnel: false)
            #expect(outOfBalanceNotice(buttons: buttons, tunnelStarted: false).traffic == .notProtected, "\(status)")
            #expect(outOfBalanceNotice(buttons: buttons, tunnelStarted: true).traffic == .held, "\(status)")
        }
        let disconnected = connectActionButtons(gateActive: true, connectionStatus: .disconnected, displayReconnectTunnel: false)
        #expect(outOfBalanceNotice(buttons: disconnected, tunnelStarted: true).traffic == .none)
        #expect(outOfBalanceNotice(buttons: disconnected, tunnelStarted: false).traffic == .none)
    }

    private static func reactionActions(
        _ steps: [(insufficient: Bool, supporter: Bool, polling: Bool, dataLimit: Bool, traffic: RefusedTraffic)]
    ) -> [InsufficientBalanceNoticeAction] {
        var actions: [InsufficientBalanceNoticeAction] = []
        let reaction = InsufficientBalanceContractReaction(disconnect: {}, notice: { actions.append($0) })
        for step in steps {
            reaction.update(
                insufficientBalance: step.insufficient,
                isSupporter: step.supporter,
                isPolling: step.polling,
                dataLimit: step.dataLimit,
                traffic: step.traffic,
                connectionStatus: .connecting
            )
        }
        return actions
    }

    @Test func theNotificationDoesNotClaimHeldWithNoTunnel() {
        #expect(Self.reactionActions([(true, false, false, false, .notProtected)])
            == [.post(dataLimit: false, traffic: .notProtected)])
    }

    @Test func theNotificationFollowsTheTunnelInPlace() {
        let actions = Self.reactionActions([
            (true, false, false, false, .notProtected),
            (true, false, false, false, .notProtected),
            (true, false, false, false, .held),
            (true, false, false, false, .held),
            (true, false, false, false, .notProtected),
            (false, false, false, false, .notProtected),
        ])
        #expect(actions == [
            .post(dataLimit: false, traffic: .notProtected),
            .update(dataLimit: false, traffic: .held),
            .update(dataLimit: false, traffic: .notProtected),
            .remove,
        ])
    }

    @Test func nothingIsPostedWithNoConnectionRequested() {
        #expect(Self.reactionActions([(true, false, false, false, .none)]).isEmpty)
        #expect(Self.reactionActions([(true, true, false, true, .none)]).isEmpty)
    }

    // MARK: a paying account refused: the data limit

    /// One gate through a sequence of readings: what it said to each.
    private static func dataLimits(_ steps: [(insufficient: Bool, plan: Plan?, polling: Bool)]) -> [Bool] {
        var gate = DataLimitGate()
        return steps.map {
            gate.observe(insufficientBalance: $0.insufficient, plan: $0.plan, isPolling: $0.polling)
        }
    }

    @Test func aDataLimitIsAPayingAccountsRefusal() {
        #expect(Self.dataLimits([(true, .supporter, false), (false, .supporter, false)]) == [true, false])
        #expect(Self.dataLimits([(true, Plan.none, false)]) == [false])
        #expect(Self.dataLimits([(false, .supporter, false)]) == [false])
        // a poll defers it
        #expect(Self.dataLimits([(true, .supporter, true), (true, .supporter, false)]) == [false, true])
    }

    @Test func aRefusalFromBeforeThePurchaseIsNoDataLimit() {
        let said = Self.dataLimits([
            (true, Plan.none, false),
            (true, Plan.none, true),
            (true, .supporter, true),
            // the purchase landed with the old refusal still standing
            (true, .supporter, false),
            (true, .supporter, false),
            // it clears, and the next one the supporter plan got for itself
            (false, .supporter, false),
            (true, .supporter, false),
        ])
        #expect(said == [false, false, false, false, false, false, true])
    }

    /// The plan not reported yet is not a plan: its first report is no upgrade.
    @Test func aDataLimitWaitsForThePlan() {
        #expect(Self.dataLimits([(true, nil, false), (true, .supporter, false)]) == [false, true])
        #expect(Self.dataLimits([(true, nil, false), (true, Plan.none, false), (true, .supporter, false)])
            == [false, false, false])
    }

    @Test func aDataLimitPostsOncePerEpisodeInItsOwnWordsAndNeverDisconnects() {
        var disconnects = 0
        var actions: [InsufficientBalanceNoticeAction] = []
        let reaction = InsufficientBalanceContractReaction(
            disconnect: { disconnects += 1 },
            notice: { actions.append($0) }
        )
        let steps: [(Bool, Bool, RefusedTraffic)] = [
            (true, true, .held),
            (true, true, .held),
            (true, true, .notProtected),
            (false, false, .notProtected),
            (true, true, .held),
        ]
        for (insufficient, dataLimit, traffic) in steps {
            reaction.update(
                insufficientBalance: insufficient,
                isSupporter: true,
                isPolling: false,
                dataLimit: dataLimit,
                traffic: traffic,
                connectionStatus: .connected
            )
        }
        #expect(actions == [
            .post(dataLimit: true, traffic: .held),
            .update(dataLimit: true, traffic: .notProtected),
            .remove,
            .post(dataLimit: true, traffic: .held),
        ])
        #expect(disconnects == 0)
    }

    @Test func aPurchaseDoesNotAnnounceADataLimit() {
        var gate = DataLimitGate()
        var actions: [InsufficientBalanceNoticeAction] = []
        let reaction = InsufficientBalanceContractReaction(disconnect: {}, notice: { actions.append($0) })
        for plan in [Plan.none, .supporter] {
            reaction.update(
                insufficientBalance: true,
                isSupporter: plan == .supporter,
                isPolling: false,
                dataLimit: gate.observe(insufficientBalance: true, plan: plan, isPolling: false),
                traffic: .held,
                connectionStatus: .connected
            )
        }
        #expect(actions == [.post(dataLimit: false, traffic: .held)])
    }

    @Test func aDataLimitHasNothingToBuy() {
        let buttons = connectActionButtons(
            gateActive: insufficientBalanceGateActive(insufficientBalance: true, plan: .supporter, isPollingSubscriptionBalance: false),
            connectionStatus: .connected,
            displayReconnectTunnel: false
        )
        #expect(!buttons.upgrade)
        #expect(buttons.disconnect)
        #expect(outOfBalanceNotice(buttons: buttons, tunnelStarted: true) == OutOfBalanceNotice(refresh: false, traffic: .none))
    }

    @Test func theAlertAndTheNotificationSayEachReasonInItsWords() {
        // the catalog's English, what a test host's language reads
        #expect(InsufficientBalanceNotice.title(dataLimit: false) == String(localized: "Insufficient balance"))
        #expect(InsufficientBalanceNotice.title(dataLimit: true) == String(localized: "Data limit reached"))
        #expect(InsufficientBalanceNotice.body(dataLimit: false, traffic: .held)
            == String(localized: "Your traffic is held in the tunnel until you upgrade or disconnect."))
        #expect(InsufficientBalanceNotice.body(dataLimit: true, traffic: .held)
            == String(localized: "Your traffic is held in the tunnel until more data is available or you disconnect."))
        for dataLimit in [false, true] {
            #expect(InsufficientBalanceNotice.body(dataLimit: dataLimit, traffic: .notProtected)
                == String(localized: "Your internet traffic is not protected."))
            #expect(InsufficientBalanceNotice.body(dataLimit: dataLimit, traffic: .none) == nil)
        }
    }

    @Test func aDataLimitShowsTheCanvasWarning() {
        #expect(connectCanvasShowsWarning(
            connectionStatus: .connected,
            displayReconnectTunnel: false,
            insufficientBalance: true,
            currentPlan: .supporter,
            dataLimitReached: true
        ))
        // the old refusal over a new plan shows nothing
        #expect(!connectCanvasShowsWarning(
            connectionStatus: .connected,
            displayReconnectTunnel: false,
            insufficientBalance: true,
            currentPlan: .supporter,
            dataLimitReached: false
        ))
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("network")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The views and the view model need the device to run, so they are read:
    /// every surface says what the policy says.
    @Test func everySurfaceReadsThePolicy() throws {
        let actions = try Self.source("Main/Connect/ConnectActions/ConnectActions.swift")
        #expect(actions.contains("tunnelStarted: tunnelConnected"))
        #expect(actions.contains("InsufficientBalanceNotice.body(dataLimit: false, traffic: notice.traffic)"))
        #expect(actions.contains("acceptance.dataLimit.notice"))
        #expect(!actions.contains("held in the tunnel"))

        let indicator = try Self.source("Main/Connect/ConnectButton/StatusIndicator/ConnectStatusIndicator.swift")
        #expect(indicator.contains("return String(localized: \"Data limit reached\")"))

        let model = try Self.source("Shared/ViewModels/ConnectViewModel.swift")
        #expect(model.contains("dataLimitGate.observe("))
        #expect(model.contains("tunnelStarted: tunnelConnected"))
        #expect(model.contains("dataLimit: dataLimit,"))
        // the notice follows the tunnel and the request
        let tunnel = try #require(model.range(of: "private func setTunnelConnected"))
        #expect(model[tunnel.upperBound...].prefix(240).contains("evaluateInsufficientBalance()"))
        let status = try #require(model.range(of: "func updateConnectionStatus()"))
        #expect(model[status.upperBound...].prefix(900).contains("evaluateInsufficientBalance()"))

        for host in ["Main/Connect/ConnectView-iOS.swift", "Main/Connect/ConnectView-macOS.swift"] {
            let view = try Self.source(host)
            #expect(view.contains("tunnelConnected: connectViewModel.tunnelConnected,\n"), "\(host)")
            #expect(view.components(separatedBy: "dataLimitReached: connectViewModel.dataLimitReached,").count == 3, "\(host)")
        }
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

    // MARK: acceptance post count

    /// The acceptance marker counts only posts the system accepted, one per
    /// record, starting from zero in a fresh process.
    @Test func noticePostsCountEachRecordFromZero() {
        let posts = InsufficientBalanceNoticePosts()
        #expect(posts.count == 0)
        posts.record()
        #expect(posts.count == 1)
        posts.record()
        #expect(posts.count == 2)
    }
}
