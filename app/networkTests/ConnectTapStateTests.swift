import Combine
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// A connect or disconnect tap shows its state at once (owner report
/// 2026-10-16: "when connect is tapped, the view should immediately change to
/// the connection state"). Two waits stood between the tap and the view:
/// - the sdk command: with the tunnel up, the controller's Connect and
///   Disconnect make blocking round trips to the extension, and they ran on
///   the main actor, so the sdk's own connecting status rendered only after
///   they returned;
/// - the start gate: a start on a stale balance fetches it first (up to five
///   seconds) and showed nothing meanwhile.
/// `HeldCommands` stands in for the sdk commands and holds each one until
/// the test lets it return, as the extension does; `HeldFetch` holds the
/// balance fetch the same way. Nothing here waits on time.
@MainActor
@Suite(.serialized)
struct ConnectTapStateTests {

    nonisolated private static let now = Date(timeIntervalSince1970: 1_000_000)
    nonisolated private static let gib: Int64 = 1024 * 1024 * 1024

    nonisolated private static func balance(_ balanceByteCount: Int64, age: TimeInterval = 0) -> WidgetBalanceSnapshot {
        WidgetBalanceSnapshot(
            updatedAt: now.addingTimeInterval(-age),
            startBalanceByteCount: gib,
            balanceByteCount: balanceByteCount,
            openTransferByteCount: 0,
            isPro: false
        )
    }

    /// The sdk's connect commands. Each is held until `release` lets one
    /// return, and reports what the sdk's controller then reports: the
    /// command's first status. A command run on the main thread cannot be
    /// held (the test releases it from there), so it returns at once and is
    /// counted: that is the main-actor wait itself. Safe for concurrent use.
    final class HeldCommands: @unchecked Sendable {
        private let stateLock = NSLock()
        private var performedCommands: [ConnectCommand] = []
        private var mainThreadCommandCount = 0
        private var sdkStatus: String
        // one signal per command that reached the sdk, one per release
        private let reached = DispatchSemaphore(value: 0)
        private let releases = DispatchSemaphore(value: 0)

        init(status: ConnectionStatus = .disconnected) {
            sdkStatus = status.rawValue
        }

        func perform(_ command: ConnectCommand) {
            reached.signal()
            if Thread.isMainThread {
                stateLock.withLock { mainThreadCommandCount += 1 }
            } else {
                releases.wait()
            }
            stateLock.withLock {
                performedCommands.append(command)
                sdkStatus = command.startStatus.rawValue
            }
        }

        /// Lets one held command return.
        func release() {
            releases.signal()
        }

        /// Returns once the next command is inside the sdk.
        func waitUntilReached() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.reached.wait()
                    continuation.resume()
                }
            }
        }

        /// The commands that returned, in order.
        var performed: [ConnectCommand] {
            stateLock.withLock { performedCommands }
        }

        var ranOnMainThread: Bool {
            stateLock.withLock { 0 < mainThreadCommandCount }
        }

        /// What the controller reports (its getConnectionStatus).
        var status: String {
            get { stateLock.withLock { sdkStatus } }
            set { stateLock.withLock { sdkStatus = newValue } }
        }
    }

    /// The start gate's balance fetch, held until `complete`.
    @MainActor
    final class HeldFetch {
        private var held: CheckedContinuation<WidgetBalanceSnapshot?, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?
        private(set) var fetchCount = 0

        func fetch() async -> WidgetBalanceSnapshot? {
            fetchCount += 1
            startWaiter?.resume()
            startWaiter = nil
            return await withCheckedContinuation { held = $0 }
        }

        /// Returns once a fetch is in flight.
        func waitUntilStarted() async {
            if 0 < fetchCount {
                return
            }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func complete(_ balance: WidgetBalanceSnapshot?) {
            held?.resume(returning: balance)
            held = nil
        }
    }

    /// Every status the view model publishes, in order.
    final class StatusRecord {
        var statuses: [ConnectionStatus?] = []
        var subscription: AnyCancellable?
    }

    private static func record(_ model: ConnectViewModel) -> StatusRecord {
        let record = StatusRecord()
        record.subscription = model.$connectionStatus.sink { record.statuses.append($0) }
        return record
    }

    /// A view model on the fake sdk with the sdk's status read once, as at
    /// launch. The balance is fresh and funded unless `cached` says
    /// otherwise; `fetch` holds the gate's fetch. The fake replaces the whole
    /// sdk call (performOnSdk), so nothing here writes the shared intent the
    /// start gate tests read.
    private static func model(
        _ commands: HeldCommands,
        cached: WidgetBalanceSnapshot? = balance(gib),
        fetch: HeldFetch? = nil
    ) -> ConnectViewModel {
        let model = ConnectViewModel()
        model.now = { now }
        model.loadCachedBalance = { cached }
        model.fetchBalance = {
            guard let fetch else {
                return nil
            }
            return await fetch.fetch()
        }
        model.performConnectCommand = { command, _, _ in
            commands.perform(command)
        }
        model.readConnectionStatus = { commands.status }
        model.updateInsufficientBalanceGuards(plan: .none, isPollingSubscriptionBalance: false)
        model.updateConnectionStatus()
        return model
    }

    // MARK: the sdk command

    /// The reported wait: the connect ran on the main actor and the view
    /// showed nothing until the extension answered. Now the connecting
    /// state is published at the tap and the main actor stays free (this
    /// test runs on it) while the sdk holds the command.
    @Test func connectTapShowsConnectingWhileTheSdkHoldsTheCommand() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        #expect(model.connectionStatus == .disconnected)

        model.connect()
        #expect(model.connectionStatus == .destinationSet)
        await commands.waitUntilReached()
        // the command is inside the sdk and has not returned
        #expect(!commands.ranOnMainThread)
        #expect(commands.performed.isEmpty)
        #expect(model.connectionStatus == .destinationSet)

        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.connectBestAvailable])
        #expect(model.connectionStatus == .destinationSet)
    }

    @Test func disconnectTapShowsDisconnectedWhileTheSdkHoldsTheCommand() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        #expect(model.connectionStatus == .connected)

        model.disconnect()
        #expect(model.connectionStatus == .disconnected)
        await commands.waitUntilReached()
        #expect(!commands.ranOnMainThread)
        #expect(commands.performed.isEmpty)
        #expect(model.connectionStatus == .disconnected)

        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.disconnect])
        #expect(model.connectionStatus == .disconnected)
    }

    /// The sdk's report of a command can reach the main actor while a later
    /// tap is still queued. A connect then a quick disconnect run in order,
    /// and the connect's report never flips the view back to connecting.
    @Test func connectThenDisconnectRunInOrderWithoutFlippingBack() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let record = Self.record(model)

        model.connect()
        #expect(model.connectionStatus == .destinationSet)
        model.disconnect()
        #expect(model.connectionStatus == .disconnected)

        await commands.waitUntilReached()
        commands.release()
        await commands.waitUntilReached()
        // the connect returned; the sdk reports it while the disconnect is held
        #expect(commands.performed == [.connectBestAvailable])
        #expect(commands.status == ConnectionStatus.destinationSet.rawValue)
        model.updateConnectionStatus()
        #expect(model.connectionStatus == .disconnected)

        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.connectBestAvailable, .disconnect])
        #expect(!commands.ranOnMainThread)
        #expect(model.connectionStatus == .disconnected)
        #expect(record.statuses == [.disconnected, .destinationSet, .disconnected])
    }

    /// A provider tap while connected: a report from before the new connect
    /// (here the outgoing window failing) arrives while the connect is held,
    /// and the view keeps the new connect's state; the sdk's later statuses
    /// then follow as before.
    @Test func reportFromTheOutgoingSessionDoesNotOverrideTheTap() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let record = Self.record(model)

        model.connect(SdkConnectLocation())
        #expect(model.connectionStatus == .destinationSet)
        await commands.waitUntilReached()
        commands.status = ConnectionStatus.connectFailed.rawValue
        model.updateConnectionStatus()
        #expect(model.connectionStatus == .destinationSet)

        commands.release()
        await model.connectCommandsSettled()
        #expect(model.connectionStatus == .destinationSet)
        commands.status = ConnectionStatus.connected.rawValue
        model.updateConnectionStatus()
        #expect(model.connectionStatus == .connected)
        #expect(record.statuses == [.connected, .destinationSet, .connected])
    }

    /// Quitting disconnects first: the wait returns once the disconnect is
    /// through the sdk, so the process never exits before it.
    @Test func quitWaitsForTheDisconnectToReachTheSdk() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)

        model.disconnect()
        await commands.waitUntilReached()
        #expect(commands.performed.isEmpty)
        DispatchQueue.global().async {
            commands.release()
        }
        model.waitForConnectCommands()
        #expect(commands.performed == [.disconnect])
    }

    // MARK: the start gate

    /// The other reported wait: a start on a stale balance fetched it first
    /// and showed nothing for up to five seconds. Now it shows connecting
    /// while the fetch runs and hands over to the admitted connect's own
    /// state with no step back to disconnected. A second tap while it waits
    /// does not stack or skip the gate.
    @Test func startWaitingOnItsBalanceShowsConnecting() async {
        let commands = HeldCommands()
        let fetch = HeldFetch()
        let model = Self.model(commands, cached: Self.balance(Self.gib, age: 30 * 60), fetch: fetch)
        let record = Self.record(model)

        model.connect()
        #expect(model.connectionStatus == .destinationSet)
        await fetch.waitUntilStarted()
        #expect(model.connectionStatus == .destinationSet)
        #expect(commands.performed.isEmpty)

        // the provider list while the start waits
        model.connect(SdkConnectLocation())
        #expect(fetch.fetchCount == 1)

        let start = model.startConnectTask
        fetch.complete(Self.balance(Self.gib))
        await start?.value
        #expect(model.connectionStatus == .destinationSet)
        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.connectBestAvailable])
        #expect(!model.isPresentedUpgradeSheet)
        #expect(model.connectionStatus == .destinationSet)
        #expect(record.statuses == [.disconnected, .destinationSet])
    }

    /// Refused on the fetched balance: back to disconnected as the upgrade
    /// sheet opens, and nothing reaches the sdk.
    @Test func refusedStartRollsBackUnderTheUpgradeSheet() async {
        let commands = HeldCommands()
        let fetch = HeldFetch()
        let model = Self.model(commands, cached: Self.balance(Self.gib, age: 30 * 60), fetch: fetch)
        let record = Self.record(model)

        model.connect()
        #expect(model.connectionStatus == .destinationSet)
        await fetch.waitUntilStarted()
        let start = model.startConnectTask
        fetch.complete(Self.balance(0))
        await start?.value
        await model.connectCommandsSettled()

        #expect(model.connectionStatus == .disconnected)
        #expect(model.isPresentedUpgradeSheet)
        #expect(model.upgradeOpenedByStartConnectBlock)
        #expect(commands.performed.isEmpty)
        #expect(record.statuses == [.disconnected, .destinationSet, .disconnected])
    }

    /// Disconnect is offered while the start waits; it ends the start, and
    /// the balance arriving afterwards connects nothing.
    @Test func disconnectWhileTheBalanceIsFetchedCancelsTheStart() async {
        let commands = HeldCommands()
        let fetch = HeldFetch()
        let model = Self.model(commands, cached: Self.balance(Self.gib, age: 30 * 60), fetch: fetch)

        model.connect()
        await fetch.waitUntilStarted()
        #expect(model.connectionStatus == .destinationSet)
        let start = model.startConnectTask
        model.disconnect()
        #expect(model.connectionStatus == .disconnected)

        await commands.waitUntilReached()
        commands.release()
        fetch.complete(Self.balance(Self.gib))
        await start?.value
        await model.connectCommandsSettled()
        #expect(commands.performed == [.disconnect])
        #expect(model.connectionStatus == .disconnected)
        #expect(!model.isPresentedUpgradeSheet)
    }

    /// Signing out while a start waits on its balance: the start belonged to
    /// the signed out account and never connects.
    @Test func signOutWhileTheBalanceIsFetchedNeverConnects() async {
        let commands = HeldCommands()
        let fetch = HeldFetch()
        let model = Self.model(commands, cached: Self.balance(Self.gib, age: 30 * 60), fetch: fetch)

        model.connect()
        await fetch.waitUntilStarted()
        let start = model.startConnectTask
        model.reset()
        #expect(model.connectionStatus == nil)

        fetch.complete(Self.balance(Self.gib))
        await start?.value
        await model.connectCommandsSettled()
        #expect(commands.performed.isEmpty)
        #expect(model.connectionStatus == nil)
    }
}
