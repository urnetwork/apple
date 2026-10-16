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
        private var statusAfterCommandValue: ConnectionStatus?
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
                sdkStatus = (statusAfterCommandValue ?? command.startStatus).rawValue
            }
        }

        /// What the controller reports once a command returns, when not the
        /// command's first status.
        var statusAfterCommand: ConnectionStatus? {
            get { stateLock.withLock { statusAfterCommandValue } }
            set { stateLock.withLock { statusAfterCommandValue = newValue } }
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

    // MARK: quitting

    #if os(macOS)
    /// The quit's device close and its answer to terminate. The close is
    /// held until `finishClosing`, and the caps fire only from `fireCap`.
    @MainActor
    final class HeldQuit {
        private(set) var settleCount = 0
        private(set) var closeCount = 0
        private(set) var replyCount = 0
        // what had reached the sdk when the device closed
        private(set) var performedAtClose: [ConnectCommand]?
        private var closed: (@MainActor () -> Void)?
        private var settleWaiter: CheckedContinuation<Void, Never>?
        private var closeWaiter: CheckedContinuation<Void, Never>?
        private var caps: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

        /// The quit as the app delegate makes it, on `model` and `commands`.
        func sequence(_ model: ConnectViewModel, _ commands: HeldCommands) -> QuitSequence {
            QuitSequence(
                settleCommands: {
                    self.settleCount += 1
                    self.settleWaiter?.resume()
                    self.settleWaiter = nil
                    await model.connectCommandsSettled()
                },
                close: { closed in
                    self.closeCount += 1
                    self.performedAtClose = commands.performed
                    self.closed = closed
                    self.closeWaiter?.resume()
                    self.closeWaiter = nil
                },
                reply: {
                    self.replyCount += 1
                },
                schedule: { delay, work in
                    self.caps.append((delay: delay, work: work))
                }
            )
        }

        /// Returns once the quit waits for the queued commands.
        func waitUntilSettling() async {
            if 0 < settleCount {
                return
            }
            await withCheckedContinuation { settleWaiter = $0 }
        }

        /// Returns once the quit closes the device.
        func waitUntilClosing() async {
            if 0 < closeCount {
                return
            }
            await withCheckedContinuation { closeWaiter = $0 }
        }

        /// The device has closed.
        func finishClosing() {
            closed?()
            closed = nil
        }

        /// Runs the work scheduled `delay` after the quit.
        func fireCap(_ delay: TimeInterval) {
            for cap in caps where cap.delay == delay {
                cap.work()
            }
        }

        var capDelays: [TimeInterval] {
            caps.map { $0.delay }.sorted()
        }
    }

    /// Disconnect, then a Dock quit, a logout or the menu's Quit: the device
    /// closes and the app answers terminate only once the disconnect is
    /// through the sdk. Answered first, the disconnect was lost and the next
    /// launch reconnected.
    @Test func quitWaitsForTheQueuedDisconnectBeforeClosing() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let quit = HeldQuit()

        model.disconnect()
        await commands.waitUntilReached()
        quit.sequence(model, commands).start()
        if quit.closeCount == 0 {
            await quit.waitUntilSettling()
        }
        // the disconnect is inside the sdk: the device stays open, no answer
        #expect(quit.closeCount == 0)
        #expect(quit.replyCount == 0)
        #expect(quit.capDelays == [QuitSequence.commandsCap, QuitSequence.cap])

        commands.release()
        await quit.waitUntilClosing()
        #expect(quit.performedAtClose == [.disconnect])
        #expect(quit.replyCount == 0)
        quit.finishClosing()
        #expect(quit.replyCount == 1)

        // the caps change nothing afterwards
        quit.fireCap(QuitSequence.commandsCap)
        quit.fireCap(QuitSequence.cap)
        #expect(quit.closeCount == 1)
        #expect(quit.replyCount == 1)
    }

    /// A command the extension does not answer holds the quit for at most
    /// the caps: the device closes at the first, the app answers at the
    /// second, and the command returning afterwards changes nothing.
    @Test func quitClosesAndAnswersAtItsCapsWhileACommandIsHeld() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let quit = HeldQuit()

        model.disconnect()
        await commands.waitUntilReached()
        quit.sequence(model, commands).start()
        if quit.closeCount == 0 {
            await quit.waitUntilSettling()
        }
        #expect(quit.closeCount == 0)
        // never longer than the quit has always taken
        #expect(QuitSequence.commandsCap < QuitSequence.cap)
        #expect(QuitSequence.cap <= 10)

        quit.fireCap(QuitSequence.commandsCap)
        #expect(quit.closeCount == 1)
        #expect(quit.performedAtClose == [])
        #expect(quit.replyCount == 0)
        // the close does not finish either
        quit.fireCap(QuitSequence.cap)
        #expect(quit.replyCount == 1)

        commands.release()
        await model.connectCommandsSettled()
        quit.finishClosing()
        #expect(commands.performed == [.disconnect])
        #expect(quit.closeCount == 1)
        #expect(quit.replyCount == 1)
    }

    /// A device whose close is held off the main thread, as the sdk's
    /// DeviceRemote.Close waits on the state lock a held command keeps
    /// through its rpc. A close on the main thread cannot be held (the test
    /// releases it from there), so it returns at once and is counted. Safe
    /// for concurrent use.
    final class HeldCloseDevice: SdkDeviceRemote, @unchecked Sendable {
        private let stateLock = NSLock()
        private var closeCountValue = 0
        private var closedOnMainThreadValue = false
        private let closing = DispatchSemaphore(value: 0)
        private let releases = DispatchSemaphore(value: 0)

        override init() {
            super.init(ref: NSObject())
        }

        override func close() {
            let mainThread = Thread.isMainThread
            stateLock.withLock {
                closeCountValue += 1
                closedOnMainThreadValue = closedOnMainThreadValue || mainThread
            }
            closing.signal()
            if !mainThread {
                releases.wait()
            }
        }

        /// Returns once a close has begun.
        func waitUntilClosing() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.closing.wait()
                    continuation.resume()
                }
            }
        }

        func releaseClose() {
            releases.signal()
        }

        var closeCount: Int {
            stateLock.withLock { closeCountValue }
        }

        var closedOnMainThread: Bool {
            stateLock.withLock { closedOnMainThreadValue }
        }
    }

    /// The quit closes the device off the main actor. Closed on it, the
    /// close waited on a held command's rpc, up to the 60 s rpc timeout,
    /// and the quit's 10 s cap, on the main actor too, could not fire.
    @Test func quitClosesTheDeviceOffTheMainActor() async {
        let device = HeldCloseDevice()
        DeviceManager.closeOffMainActor(device)
        await device.waitUntilClosing()
        // the close is held, and the main actor (this test) goes on
        #expect(device.closedOnMainThread == false)
        #expect(device.closeCount == 1)
        device.releaseClose()
    }

    /// Nothing queued: the quit closes the device at once and answers when
    /// it has closed, as before.
    @Test func quitWithNothingQueuedClosesAtOnce() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let quit = HeldQuit()

        quit.sequence(model, commands).start()
        await quit.waitUntilClosing()
        #expect(quit.replyCount == 0)
        quit.finishClosing()
        #expect(quit.replyCount == 1)
        #expect(commands.performed.isEmpty)
    }
    #endif

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

    // MARK: suspend, setup and reset while a command is pending

    /// A device with no sdk behind it, for setup and suspend: it reports
    /// `location`, and `reportLocation` calls its location listeners as the
    /// sdk's event does, which reaches the app after the command returns.
    /// Every call the view model and the device stores (DeviceStores) make
    /// on a device is answered here, so nothing reaches the Go side; the
    /// stores' controllers are fakes too, and their listeners and the
    /// device's report on demand (`storeListeners`,
    /// `reportControllerListeners`).
    ///
    /// Each call made on the main thread is recorded (`mainThreadCalls`):
    /// on the sdk's DeviceRemote every one of them, its getters, listener
    /// adds, sub closes and controller closes, takes the device's state lock,
    /// which a held command keeps through its rpc, so made on the main
    /// thread it would wait there. Safe for concurrent use.
    final class FakeDevice: SdkDeviceRemote, @unchecked Sendable {
        private let stateLock = NSLock()
        private var location: SdkConnectLocation?
        private var locationListeners: [Int: SdkConnectLocationChangeListenerProtocol] = [:]
        private var tunnelStarted: Bool
        private var tunnelListeners: [Int: SdkTunnelChangeListenerProtocol] = [:]
        private var nextListenerId = 0
        private var mainThreadCallNames: [String] = []
        private var callNames: [String] = []
        private var afterTunnelReadValue: (() -> Void)?
        private var afterLocationReadValue: (() -> Void)?

        init(location: SdkConnectLocation?, tunnelStarted: Bool = false) {
            self.location = location
            self.tunnelStarted = tunnelStarted
            super.init(ref: NSObject())
        }

        /// The tunnel started or stopped and the device reports it.
        func reportTunnel(_ started: Bool) {
            let listeners = stateLock.withLock {
                tunnelStarted = started
                return Array(tunnelListeners.values)
            }
            for listener in listeners {
                listener.tunnelChanged(started)
            }
        }

        /// The device's location changed and the sdk reports it.
        func reportLocation(_ location: SdkConnectLocation?) {
            let listeners = stateLock.withLock {
                self.location = location
                return Array(locationListeners.values)
            }
            for listener in listeners {
                listener.connectLocationChanged(location)
            }
        }

        /// The device's location changed, not reported yet: a command sets it
        /// before the device's event reaches the app.
        func setLocationUnreported(_ location: SdkConnectLocation?) {
            stateLock.withLock { self.location = location }
        }

        /// The same for the tunnel.
        func setTunnelUnreported(_ started: Bool) {
            stateLock.withLock { tunnelStarted = started }
        }

        /// Runs once, off the main thread, as a read of the tunnel answers:
        /// the device changes right after it, and its report reaches the
        /// main thread before the read's answer does.
        func afterTunnelRead(_ change: @escaping () -> Void) {
            stateLock.withLock { afterTunnelReadValue = change }
        }

        /// The same for a read of the location.
        func afterLocationRead(_ change: @escaping () -> Void) {
            stateLock.withLock { afterLocationReadValue = change }
        }

        var hasLocationListener: Bool {
            stateLock.withLock { !locationListeners.isEmpty }
        }

        var hasTunnelListener: Bool {
            stateLock.withLock { !tunnelListeners.isEmpty }
        }

        var tunnelListenerCount: Int {
            stateLock.withLock { tunnelListeners.count }
        }

        /// The calls made on the main thread since the last `forgetMainThreadCalls`.
        var mainThreadCalls: [String] {
            stateLock.withLock { mainThreadCallNames }
        }

        func forgetMainThreadCalls() {
            stateLock.withLock { mainThreadCallNames = [] }
        }

        /// How many times `name` was called, on any thread.
        func callCount(_ name: String) -> Int {
            stateLock.withLock { callNames.filter { $0 == name }.count }
        }

        private func record(_ name: String) {
            let mainThread = Thread.isMainThread
            stateLock.withLock {
                callNames.append(name)
                if mainThread {
                    mainThreadCallNames.append(name)
                }
            }
        }

        override func getConnectLocation() -> SdkConnectLocation? {
            record("getConnectLocation")
            let (location, change) = stateLock.withLock {
                let change = Thread.isMainThread ? nil : afterLocationReadValue
                if change != nil {
                    afterLocationReadValue = nil
                }
                return (self.location, change)
            }
            change?()
            return location
        }

        override func getDefaultLocation() -> SdkConnectLocation? {
            record("getDefaultLocation")
            return nil
        }

        override func getTunnelStarted() -> Bool {
            record("getTunnelStarted")
            let (tunnelStarted, change) = stateLock.withLock {
                let change = Thread.isMainThread ? nil : afterTunnelReadValue
                if change != nil {
                    afterTunnelReadValue = nil
                }
                return (self.tunnelStarted, change)
            }
            change?()
            return tunnelStarted
        }

        override func getContractStatus() -> SdkContractStatus? {
            record("getContractStatus")
            return nil
        }

        override func add(_ listener: SdkConnectLocationChangeListenerProtocol?) -> SdkSubProtocol? {
            record("addConnectLocationChangeListener")
            let id = stateLock.withLock {
                nextListenerId += 1
                locationListeners[nextListenerId] = listener
                return nextListenerId
            }
            return FakeSub { [weak self] in
                self?.record("closeConnectLocationChangeListener")
                self?.stateLock.withLock { self?.locationListeners[id] = nil }
            }
        }

        override func add(_ listener: SdkTunnelChangeListenerProtocol?) -> SdkSubProtocol? {
            record("addTunnelChangeListener")
            let id = stateLock.withLock {
                nextListenerId += 1
                tunnelListeners[nextListenerId] = listener
                return nextListenerId
            }
            return FakeSub { [weak self] in
                self?.record("closeTunnelChangeListener")
                self?.stateLock.withLock { self?.tunnelListeners[id] = nil }
            }
        }

        override func add(_ listener: SdkContractStatusChangeListenerProtocol?) -> SdkSubProtocol? {
            record("addContractStatusChangeListener")
            return FakeSub { [weak self] in
                self?.record("closeContractStatusChangeListener")
            }
        }

        override func close(_ vc: SdkConnectViewController?) {
            record("closeConnectViewController")
            vc?.close()
        }

        // the window's controller, as NetworkApp.setupConnectViewModel opens it
        override func openConnectViewController() -> SdkConnectViewController? {
            record("openConnectViewController")
            return FakeConnectViewController()
        }

        // MARK: the device stores' calls

        /// The device listeners the stores add, each with what it reports.
        let storeListeners = FakeListeners()
        private var openedControllers: [FakeControllerRecord] = []

        /// The controllers the stores opened on this device, in order.
        var controllers: [FakeControllerRecord] {
            stateLock.withLock { openedControllers }
        }

        /// The controller opened with `name` (its open call), the last one.
        func controller(_ name: String) -> FakeControllerRecord? {
            controllers.last { $0.name == name }
        }

        /// The calls made on the main thread on the controllers opened here.
        var controllerMainThreadCalls: [String] {
            controllers.flatMap { $0.calls.mainThreadCalls }
        }

        func forgetControllerMainThreadCalls() {
            for controller in controllers {
                controller.calls.forget()
            }
        }

        /// The listeners of every controller opened here report, as the
        /// sdk's controllers do after a change.
        func reportControllerListeners() {
            for controller in controllers {
                controller.listeners.reportAll()
            }
        }

        private func opened<T>(_ name: String, _ controller: T, _ calls: FakeCalls, _ listeners: FakeListeners) -> T {
            record(name)
            stateLock.withLock {
                openedControllers.append(FakeControllerRecord(name: name, calls: calls, listeners: listeners))
            }
            return controller
        }

        private func addStoreListener(_ name: String, _ report: @escaping () -> Void) -> SdkSubProtocol? {
            record("add\(name)")
            return storeListeners.add(report) { [weak self] in
                self?.record("close\(name)")
            }
        }

        override func openContractViewController() -> SdkContractViewController? {
            let vc = FakeContractViewController()
            return opened("openContractViewController", vc, vc.calls, vc.listeners)
        }

        override func close(_ vc: SdkContractViewController?) {
            record("closeContractViewController")
            vc?.close()
        }

        override func getProviderPacketStats() -> SdkPacketStats? {
            record("getProviderPacketStats")
            return nil
        }

        override func openBlockActionViewController() -> SdkBlockActionViewController? {
            let vc = FakeBlockActionViewController()
            return opened("openBlockActionViewController", vc, vc.calls, vc.listeners)
        }

        override func close(_ vc: SdkBlockActionViewController?) {
            record("closeBlockActionViewController")
            vc?.close()
        }

        override func add(_ listener: SdkBlockActionOverridesChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("BlockActionOverridesChangeListener") {
                listener?.blockActionOverridesChanged(nil)
            }
        }

        override func getBlockActionOverrides() -> SdkBlockActionOverrideList? {
            record("getBlockActionOverrides")
            let overrides = stateLock.withLock { blockActionOverridesValue }
            heldRead("getBlockActionOverrides")
            guard let overrides, let list = SdkBlockActionOverrideList() else {
                return nil
            }
            for override in overrides {
                list.add(override)
            }
            return list
        }

        override func add(_ override: SdkBlockActionOverride?) {
            record("addBlockActionOverride")
            guard let override else {
                return
            }
            stateLock.withLock {
                blockActionOverridesValue = (blockActionOverridesValue ?? []).filter {
                    $0.overrideId?.idStr != override.overrideId?.idStr
                } + [override]
            }
        }

        override func setBlockActionOverrides(_ overrides: SdkBlockActionOverrideList?) {
            record("setBlockActionOverrides")
            var values: [SdkBlockActionOverride] = []
            if let overrides {
                for i in 0..<overrides.len() {
                    if let override = overrides.get(i) {
                        values.append(override)
                    }
                }
            }
            stateLock.withLock { blockActionOverridesValue = values }
        }

        override func removeBlockActionOverride(_ overrideId: SdkId?) {
            record("removeBlockActionOverride")
            stateLock.withLock {
                blockActionOverridesValue = blockActionOverridesValue?.filter {
                    $0.overrideId?.idStr != overrideId?.idStr
                }
            }
        }

        // reports the rpc up
        override func add(_ listener: SdkRemoteChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("RemoteChangeListener") {
                listener?.remoteChanged(true)
            }
        }

        override func getConnected() -> Bool {
            record("getConnected")
            return stateLock.withLock { remoteConnectedValue }
        }

        override func add(_ listener: SdkDnsResolverSettingsChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("DnsResolverSettingsChangeListener") {
                listener?.dnsResolverSettingsChanged(nil)
            }
        }

        override func getDnsResolverSettings() -> SdkDnsResolverSettings? {
            record("getDnsResolverSettings")
            let settings = stateLock.withLock { dnsResolverSettingsValue }
            heldRead("getDnsResolverSettings")
            return settings
        }

        override func setDnsResolverSettings(_ dnsResolverSettings: SdkDnsResolverSettings?) {
            record("setDnsResolverSettings")
            stateLock.withLock { dnsResolverSettingsValue = dnsResolverSettings }
        }

        // MARK: what the stores read

        private var dnsResolverSettingsValue: SdkDnsResolverSettings?
        private var transportSettingsValue: SdkTransportSettings?
        private var providerTransportSettingsValue: SdkTransportSettings?
        private var remoteConnectedValue = false
        private var blockActionOverridesValue: [SdkBlockActionOverride]?
        private var heldReadNames: Set<String> = []
        private let readHeld = DispatchSemaphore(value: 0)
        private let readReleases = DispatchSemaphore(value: 0)

        /// The dns resolver settings the device answers, nil for none.
        var dnsResolverSettings: SdkDnsResolverSettings? {
            get { stateLock.withLock { dnsResolverSettingsValue } }
            set { stateLock.withLock { dnsResolverSettingsValue = newValue } }
        }

        /// Whether its rpc to the extension is up (GetRemoteConnected).
        var remoteConnected: Bool {
            get { stateLock.withLock { remoteConnectedValue } }
            set { stateLock.withLock { remoteConnectedValue = newValue } }
        }

        /// The split rules the device answers, nil for none.
        var blockActionOverrides: [SdkBlockActionOverride]? {
            get { stateLock.withLock { blockActionOverridesValue } }
            set { stateLock.withLock { blockActionOverridesValue = newValue } }
        }

        /// The next read of `name` made off the main thread answers what the
        /// device has as it starts, and returns only once `releaseRead` lets
        /// it, like an rpc in flight: the device can change meanwhile.
        func holdNextRead(_ name: String) {
            stateLock.withLock { _ = heldReadNames.insert(name) }
        }

        /// Returns once a held read has started.
        func waitUntilReadHeld() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.readHeld.wait()
                    continuation.resume()
                }
            }
        }

        func releaseRead() {
            readReleases.signal()
        }

        private func heldRead(_ name: String) {
            if Thread.isMainThread {
                return
            }
            let held = stateLock.withLock { heldReadNames.remove(name) != nil }
            if held {
                readHeld.signal()
                readReleases.wait()
            }
        }

        // the transport listeners report a policy and a status; the getters
        // answer none
        override func add(_ listener: SdkTransportSettingsChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("TransportSettingsChangeListener") {
                listener?.transportSettingsChanged(SdkDefaultTransportSettings())
            }
        }

        override func add(_ listener: SdkProviderTransportSettingsChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("ProviderTransportSettingsChangeListener") {
                listener?.providerTransportSettingsChanged(SdkDefaultProviderTransportSettings())
            }
        }

        override func add(_ listener: SdkTransportStatusChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("TransportStatusChangeListener") {
                listener?.transportStatusChanged(SdkTransportStatus())
            }
        }

        override func add(_ listener: SdkProviderTransportStatusChangeListenerProtocol?) -> SdkSubProtocol? {
            addStoreListener("ProviderTransportStatusChangeListener") {
                listener?.providerTransportStatusChanged(SdkTransportStatus())
            }
        }

        override func getTransportSettings() -> SdkTransportSettings? {
            record("getTransportSettings")
            return stateLock.withLock { transportSettingsValue }
        }

        override func getProviderTransportSettings() -> SdkTransportSettings? {
            record("getProviderTransportSettings")
            return stateLock.withLock { providerTransportSettingsValue }
        }

        override func setTransportSettings(_ transportSettings: SdkTransportSettings?) {
            record("setTransportSettings")
            stateLock.withLock { transportSettingsValue = transportSettings }
        }

        override func setProviderTransportSettings(_ transportSettings: SdkTransportSettings?) {
            record("setProviderTransportSettings")
            stateLock.withLock { providerTransportSettingsValue = transportSettings }
        }

        override func getTransportStatus() -> SdkTransportStatus? {
            record("getTransportStatus")
            return nil
        }

        override func getProviderTransportStatus() -> SdkTransportStatus? {
            record("getProviderTransportStatus")
            return nil
        }

        override func openPeerViewController() -> SdkPeerViewController? {
            let vc = FakePeerViewController()
            return opened("openPeerViewController", vc, vc.calls, vc.listeners)
        }

        override func close(_ vc: SdkPeerViewController?) {
            record("closePeerViewController")
            vc?.close()
        }

        override func getNetworkPeers() -> SdkNetworkPeers? {
            record("getNetworkPeers")
            return nil
        }

        override func openProviderStatusViewController() -> SdkProviderStatusViewController? {
            let vc = FakeProviderStatusViewController()
            return opened("openProviderStatusViewController", vc, vc.calls, vc.listeners)
        }

        override func close(_ vc: SdkProviderStatusViewController?) {
            record("closeProviderStatusViewController")
            vc?.close()
        }

        // the reliability store reads on its own queue
        override func getReliabilitySettings() -> SdkReliabilitySettings? {
            record("getReliabilitySettings")
            return nil
        }

        override func getReliabilityMetrics() -> SdkReliabilityMetrics? {
            record("getReliabilityMetrics")
            return nil
        }

        override func getExits() -> SdkExitList? {
            record("getExits")
            return nil
        }
    }

    /// Listeners a fake keeps, each with what it reports when the fake
    /// reports a change (`reportAll`). Safe for concurrent use.
    final class FakeListeners: @unchecked Sendable {
        private let stateLock = NSLock()
        private var nextId = 0
        private var reports: [Int: () -> Void] = [:]

        func add(_ report: @escaping () -> Void, onClose: @escaping () -> Void = {}) -> SdkSubProtocol {
            let id = stateLock.withLock {
                nextId += 1
                reports[nextId] = report
                return nextId
            }
            return FakeSub { [weak self] in
                onClose()
                self?.stateLock.withLock { self?.reports[id] = nil }
            }
        }

        /// The listeners still open.
        var count: Int {
            stateLock.withLock { reports.count }
        }

        func reportAll() {
            let reports = stateLock.withLock { Array(self.reports.values) }
            for report in reports {
                report()
            }
        }
    }

    /// The calls a fake controller answered on the main thread, and its
    /// closes. Safe for concurrent use.
    final class FakeCalls: @unchecked Sendable {
        private let stateLock = NSLock()
        private var mainThreadCallNames: [String] = []
        private var closeCountValue = 0

        func record(_ name: String) {
            if Thread.isMainThread {
                stateLock.withLock { mainThreadCallNames.append(name) }
            }
        }

        func recordClose() {
            stateLock.withLock { closeCountValue += 1 }
        }

        var mainThreadCalls: [String] {
            stateLock.withLock { mainThreadCallNames }
        }

        var closeCount: Int {
            stateLock.withLock { closeCountValue }
        }

        func forget() {
            stateLock.withLock { mainThreadCallNames = [] }
        }
    }

    /// A controller the stores opened on a FakeDevice, by its open call.
    struct FakeControllerRecord {
        let name: String
        let calls: FakeCalls
        let listeners: FakeListeners
    }

    /// The throughput store's controller with no sdk behind it: no points,
    /// and its listeners are its own. Safe for concurrent use.
    final class FakeContractViewController: SdkContractViewController, @unchecked Sendable {
        let calls = FakeCalls()
        let listeners = FakeListeners()

        override init() {
            super.init(ref: NSObject())
        }

        override func add(_ listener: SdkThroughputListenerProtocol?) -> SdkSubProtocol? {
            listeners.add { listener?.throughputChanged() }
        }

        override func getWindowDurationSeconds() -> Int {
            calls.record("getWindowDurationSeconds")
            return 60
        }

        override func getThroughputPoints() -> SdkThroughputPointList? {
            calls.record("getThroughputPoints")
            return nil
        }

        override func getProviderThroughputPoints() -> SdkThroughputPointList? {
            calls.record("getProviderThroughputPoints")
            return nil
        }

        override func getExtenderThroughputPoints() -> SdkThroughputPointList? {
            calls.record("getExtenderThroughputPoints")
            return nil
        }

        override func getTransportDistribution() -> SdkTransportDistribution? {
            calls.record("getTransportDistribution")
            return nil
        }

        override func getProviderTransportDistribution() -> SdkTransportDistribution? {
            calls.record("getProviderTransportDistribution")
            return nil
        }

        override func getProviderPacketStats() -> SdkPacketStats? {
            calls.record("getProviderPacketStats")
            return nil
        }

        override func close() {
            calls.recordClose()
        }
    }

    /// The split rule store's controller with no sdk behind it. Safe for
    /// concurrent use.
    final class FakeBlockActionViewController: SdkBlockActionViewController, @unchecked Sendable {
        let calls = FakeCalls()
        let listeners = FakeListeners()

        override init() {
            super.init(ref: NSObject())
        }

        override func add(_ listener: SdkBlockActionsListenerProtocol?) -> SdkSubProtocol? {
            listeners.add { listener?.blockActionsChanged() }
        }

        override func add(_ listener: SdkBlockActionStatsListenerProtocol?) -> SdkSubProtocol? {
            listeners.add { listener?.blockActionStatsChanged() }
        }

        override func getBlockActions() -> SdkBlockActionList? {
            calls.record("getBlockActions")
            return nil
        }

        override func getBlockStats() -> SdkBlockStats? {
            calls.record("getBlockStats")
            return nil
        }

        override func close() {
            calls.recordClose()
        }
    }

    /// The peer store's controller with no sdk behind it. Safe for
    /// concurrent use.
    final class FakePeerViewController: SdkPeerViewController, @unchecked Sendable {
        let calls = FakeCalls()
        let listeners = FakeListeners()

        override init() {
            super.init(ref: NSObject())
        }

        override func add(_ listener: SdkPeersListenerProtocol?) -> SdkSubProtocol? {
            listeners.add { listener?.peersChanged(nil) }
        }

        override func start() {
            calls.record("start")
        }

        override func getPeers() -> SdkNetworkPeerList? {
            calls.record("getPeers")
            return nil
        }

        override func getConnectedCount() -> Int {
            calls.record("getConnectedCount")
            return 0
        }

        override func close() {
            calls.recordClose()
        }
    }

    /// The provider status store's controller with no sdk behind it. Safe
    /// for concurrent use.
    final class FakeProviderStatusViewController: SdkProviderStatusViewController, @unchecked Sendable {
        let calls = FakeCalls()
        let listeners = FakeListeners()

        override init() {
            super.init(ref: NSObject())
        }

        override func add(_ listener: SdkProviderStatusListenerProtocol?) -> SdkSubProtocol? {
            listeners.add { listener?.providerStatusChanged() }
        }

        override func start() {
            calls.record("start")
        }

        override func stop() {
            calls.record("stop")
        }

        override func getProviderStatus() -> SdkProviderStatus? {
            calls.record("getProviderStatus")
            return nil
        }

        override func getIsLoaded() -> Bool {
            calls.record("getIsLoaded")
            return false
        }

        override func getLastFetchError() -> String {
            calls.record("getLastFetchError")
            return ""
        }

        override func close() {
            calls.recordClose()
        }
    }

    /// A presented controller with no sdk behind it: no grid, its listeners
    /// are its own (closing them waits on nothing), and it counts its closes.
    /// Safe for concurrent use.
    final class FakeConnectViewController: SdkConnectViewController, @unchecked Sendable {
        private let stateLock = NSLock()
        private var closeCountValue = 0

        override init() {
            super.init(ref: NSObject())
        }

        var closeCount: Int {
            stateLock.withLock { closeCountValue }
        }

        override func add(_ listener: SdkGridListenerProtocol?) -> SdkSubProtocol? {
            FakeSub {}
        }

        override func add(_ listener: SdkConnectionStatusListenerProtocol?) -> SdkSubProtocol? {
            FakeSub {}
        }

        override func add(_ listener: SdkSelectedLocationListenerProtocol?) -> SdkSubProtocol? {
            FakeSub {}
        }

        override func getGrid() -> SdkConnectGrid? {
            nil
        }

        override func getConnectionStatus() -> String {
            ""
        }

        override func close() {
            stateLock.withLock { closeCountValue += 1 }
        }
    }

    final class FakeSub: NSObject, SdkSubProtocol {
        private let onClose: () -> Void

        init(_ onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func close() {
            onClose()
        }
    }

    /// Returns once what was queued on the main queue so far has run: the
    /// listeners hop there.
    private static func mainQueueDrained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Returns once the device work queued on the command queue so far has
    /// run and applied on the main thread (the suspended view model's
    /// listeners and reads, the closes), and the closes that applying queued
    /// in turn (a retired listener's) have run too.
    private static func deviceWorkSettled(_ model: ConnectViewModel) async {
        await model.connectCommandsSettled()
        await model.connectCommandsSettled()
    }

    /// A location with an id: two of them are the same location when their
    /// ids are.
    nonisolated private static func location(bestAvailable: Bool) -> SdkConnectLocation {
        let id = SdkConnectLocationId()
        id.bestAvailable = bestAvailable
        let location = SdkConnectLocation()
        location.connectLocationId = id
        return location
    }

    /// `model`'s commands move `device`'s location as the sdk's do: once a
    /// command returns, the device's getter answers with what it set (a
    /// connect its location, a disconnect none), and its listener hears it
    /// later (`reportLocation`).
    private static func commandsMoveLocation(_ model: ConnectViewModel, _ commands: HeldCommands, _ device: FakeDevice) {
        model.performConnectCommand = { command, _, _ in
            commands.perform(command)
            switch command {
            case .connect(let location):
                device.setLocationUnreported(location)
            case .connectBestAvailable:
                device.setLocationUnreported(Self.location(bestAvailable: true))
            case .rebuild(let fallback):
                device.setLocationUnreported(fallback ?? Self.location(bestAvailable: true))
            case .disconnect:
                device.setLocationUnreported(nil)
            }
        }
    }

    /// The macOS menu bar's Disconnect with the window hidden (suspended):
    /// the status follows the device's location, and the sdk reports the
    /// disconnect only after the command returns. The view keeps the tap's
    /// state through the return instead of going back to the location read
    /// before the command.
    @Test func suspendedDisconnectNeverFlipsBackToTheOldLocation() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: SdkConnectLocation())
        Self.commandsMoveLocation(model, commands, device)
        let record = Self.record(model)

        model.disconnect()
        await commands.waitUntilReached()
        // the window hides while the extension holds the disconnect: the
        // device still reports the location, and no controller is presented
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        #expect(model.connectionStatus == .disconnected)

        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(commands.performed == [.disconnect])
        #expect(device.hasLocationListener)
        #expect(model.connectionStatus == .disconnected)

        device.reportLocation(nil)
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .disconnected)
        #expect(record.statuses == [.connected, .disconnected])
    }

    /// The same for the menu bar's Connect with the window hidden.
    @Test func suspendedConnectNeverFlipsBackToDisconnected() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        let record = Self.record(model)
        #expect(model.connectionStatus == .disconnected)

        model.connect()
        #expect(model.connectionStatus == .destinationSet)
        await commands.waitUntilReached()
        commands.release()
        await model.connectCommandsSettled()
        #expect(model.connectionStatus == .destinationSet)

        device.reportLocation(SdkConnectLocation())
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .destinationSet)
        #expect(record.statuses == [.disconnected, .destinationSet])
    }

    /// The window shows again while a menu bar connect is held: the new
    /// controller's report from before the connect does not flip the view,
    /// the device's location listener closes once the connect returns (its
    /// close takes the device's state lock) and reports nothing meanwhile,
    /// and the status is read from the controller again.
    @Test func setupWhileAConnectIsHeldReadsTheControllerOnceItReturns() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }

        model.connect()
        await commands.waitUntilReached()
        model.readConnectionStatus = { commands.status }
        model.setup(api: nil, device: device, connectViewController: nil)
        #expect(model.connectionStatus == .destinationSet)
        device.reportLocation(Self.location(bestAvailable: true))
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .destinationSet)
        #expect(!model.connectionStatusFromLocation)

        // the controller already reports connected when the connect returns
        commands.statusAfterCommand = .connected
        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(!device.hasLocationListener)
        #expect(model.connectionStatus == .connected)
    }

    /// Suspended and set up again with nothing pending: the reports from
    /// each source show as before.
    @Test func suspendAndSetupWithNothingPendingFollowTheirSources() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)

        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        #expect(model.connectionStatus == .disconnected)
        device.reportLocation(SdkConnectLocation())
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .destinationSet)

        model.readConnectionStatus = { commands.status }
        model.setup(api: nil, device: device, connectViewController: nil)
        #expect(model.connectionStatus == .connected)
    }

    // MARK: suspend while a command is held

    /// Hiding the window (macOS) or backgrounding the app (iOS) while the
    /// window's connect is held in the sdk. On the sdk's DeviceRemote every
    /// call suspend makes on the device waits on its state lock, which the
    /// held command keeps through its rpc to the extension, up to the 60 s
    /// rpc timeout: closing the window's tunnel and contract listeners and
    /// its controller, adding the hidden listeners, reading the tunnel and
    /// the location. Made on the main actor, they froze it for as long. Now
    /// none is made there: they run once the command returns, after it, and
    /// the reads answer with what it left. A report from a window listener
    /// still closing changes nothing.
    @Test func suspendWhileACommandIsHeldMakesNoDeviceCallOnTheMainThread() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        model.saveConnectLocation = { _, _ in }
        let device = FakeDevice(location: nil)
        Self.commandsMoveLocation(model, commands, device)
        let viewController = FakeConnectViewController()
        model.setup(api: nil, device: device, connectViewController: viewController)
        let location = Self.location(bestAvailable: false)

        model.connect(location)
        await commands.waitUntilReached()
        // setup's own calls stay on the main actor: not the hide path
        device.forgetMainThreadCalls()
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        #expect(device.mainThreadCalls == [])
        #expect(viewController.closeCount == 0)
        #expect(model.connectionStatus == .destinationSet)

        // the tunnel comes up with the connect; the window's listener is the
        // only one so far, and it is closing
        device.setTunnelUnreported(true)
        device.reportTunnel(true)
        await Self.mainQueueDrained()
        #expect(!model.tunnelConnected)

        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(device.mainThreadCalls == [])
        #expect(viewController.closeCount == 1)
        #expect(device.hasLocationListener)
        #expect(device.tunnelListenerCount == 1)
        #expect(model.tunnelConnected)
        #expect(model.connectionStatus == .destinationSet)
        #expect(model.connectionStatusFromLocation)
    }

    /// The device changes right after a hidden read answers, and its report
    /// reaches the main actor before the read's answer does: the report is
    /// newer, and the read's older answer never replaces it. Applied, the
    /// menu bar kept a tunnel and a location the device no longer had, until
    /// its next change.
    @Test func aReportNewerThanTheHiddenReadsWins() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: Self.location(bestAvailable: false), tunnelStarted: true)
        device.afterTunnelRead { device.reportTunnel(false) }
        device.afterLocationRead { device.reportLocation(nil) }

        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        #expect(!model.tunnelConnected)
        #expect(model.connectionStatus == .disconnected)
        #expect(!model.connectionStatusFromLocation)
    }

    /// The window shows again before the hidden listeners and reads, queued
    /// behind a held command, have run. They run once the command returns
    /// and change nothing: the controller is in charge again. A report their
    /// listener makes before it closes is dropped too.
    @Test func aSetupBeforeTheHiddenReadsRunDropsThem() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: Self.location(bestAvailable: false), tunnelStarted: true)

        model.connect()
        await commands.waitUntilReached()
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { commands.status }
        model.setup(api: nil, device: device, connectViewController: nil)
        // the hidden listener hears the location go right after its read
        device.afterLocationRead { device.reportLocation(nil) }

        commands.statusAfterCommand = .connected
        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(model.connectionStatus == .connected)
        #expect(!model.connectionStatusFromLocation)
        #expect(!device.hasLocationListener)
        // setup's tunnel listener stays, the hidden one is closed
        #expect(device.tunnelListenerCount == 1)
        #expect(model.tunnelConnected)
    }

    /// Signed out while hidden, before the hidden listeners and reads, queued
    /// behind a held command, have run: they change nothing on the reset
    /// view model, and their listeners close.
    @Test func aResetBeforeTheHiddenReadsRunDropsThem() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: Self.location(bestAvailable: false), tunnelStarted: true)

        model.connect()
        await commands.waitUntilReached()
        model.suspend(api: nil, device: device)
        model.reset()
        model.readConnectionStatus = { nil }

        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(model.connectionStatus == nil)
        #expect(!model.tunnelConnected)
        #expect(model.selectedProvider == nil)
        #expect(!device.hasLocationListener)
        #expect(!device.hasTunnelListener)
    }

    /// The connect views read the tunnel again as they appear: on the
    /// command queue, after the commands queued so far, never on the main
    /// actor, where the getter waited on a held command too.
    @Test func refreshingTheTunnelMakesNoDeviceCallOnTheMainThread() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        model.setup(api: nil, device: device, connectViewController: nil)
        await Self.deviceWorkSettled(model)
        #expect(!model.tunnelConnected)

        model.connect()
        await commands.waitUntilReached()
        device.forgetMainThreadCalls()
        device.setTunnelUnreported(true)
        model.refreshTunnelStatus()
        #expect(device.mainThreadCalls == [])
        #expect(!model.tunnelConnected)

        commands.release()
        await model.connectCommandsSettled()
        #expect(model.tunnelConnected)
    }

    // MARK: the device stores while a command is held

    /// The window's device stores on `device`, as NetworkApp sets them up:
    /// closing on `model`'s command queue, with the provider statistics
    /// showing (the provider status controller opens only then).
    private static func deviceStores(_ model: ConnectViewModel, on device: FakeDevice) -> DeviceStores {
        let stores = DeviceStores(deviceWorkQueue: model.connectCommandQueue)
        stores.providerStatusStore.setVisible(true)
        stores.setup(device, localState: nil)
        return stores
    }

    /// Hiding the window (macOS) or backgrounding the app (iOS) with every
    /// device store set up, while the window's connect is held in the sdk.
    /// NetworkApp resets the stores right after it suspends the view model,
    /// and the reset closed the stores' device listeners (dns, transport,
    /// split rules, the remote's) and their controllers (throughput, split
    /// rules, peers, provider status) on the main actor. On the sdk's
    /// DeviceRemote each waits on the device's state lock, which the held
    /// command keeps through its rpc, up to the 60 s rpc timeout, and the
    /// main actor froze for as long. Now none is made there: they close once
    /// the command returns, after it.
    @Test func hidingWithEveryDeviceStoreSetUpMakesNoDeviceCallOnTheMainThread() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        model.setup(api: nil, device: device, connectViewController: FakeConnectViewController())
        let stores = Self.deviceStores(model, on: device)
        await Self.deviceWorkSettled(model)
        // dns 2, transport 4, split rules 2, peers 1
        #expect(device.storeListeners.count == 9)
        #expect(device.controllers.count == 4)

        model.connect()
        await commands.waitUntilReached()
        // setup's own calls stay on the main actor: not the hide path
        device.forgetMainThreadCalls()
        // as NetworkApp.updateConnectViewModel applies the hide
        model.suspend(api: nil, device: device)
        stores.reset()
        model.readConnectionStatus = { nil }
        #expect(device.mainThreadCalls == [])
        #expect(device.storeListeners.count == 9)
        #expect(device.controllers.map { $0.calls.closeCount } == [0, 0, 0, 0])

        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(device.mainThreadCalls == [])
        #expect(device.storeListeners.count == 0)
        #expect(device.controllers.map { $0.calls.closeCount } == [1, 1, 1, 1])
    }

    /// A store's listeners report until they close, and a report already on
    /// its way to the main actor lands after the reset. With the closes
    /// behind a held command that lasts as long as the command. Applied, the
    /// hidden stores showed the device's transport policy and status, and its
    /// peers as available, again. From its reset on, a store drops them.
    @Test func reportsAfterTheDeviceStoresResetChangeNothing() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        let stores = Self.deviceStores(model, on: device)
        await Self.deviceWorkSettled(model)

        model.connect()
        await commands.waitUntilReached()
        // reports on their way to the main actor as the window hides
        device.storeListeners.reportAll()
        device.reportControllerListeners()
        stores.reset()
        // and the listeners still closing report again
        device.storeListeners.reportAll()
        device.forgetMainThreadCalls()
        await Self.mainQueueDrained()
        #expect(stores.transportSettingsStore.settings(.client) == nil)
        #expect(stores.transportSettingsStore.settings(.provider) == nil)
        #expect(stores.transportSettingsStore.status(.client) == nil)
        #expect(stores.transportSettingsStore.status(.provider) == nil)
        #expect(!stores.networkPeersStore.peersAvailable)
        #expect(device.mainThreadCalls == [])

        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(device.storeListeners.count == 0)
    }

    /// The same reports landing after the next setup, on the next device (a
    /// sign-in, or the window shown again), before the previous device's
    /// listeners have closed. Applied, they showed the previous device's
    /// transport policy and peer presence on the next device's stores, and
    /// read the next device and its controllers on the main actor.
    @Test func reportsFromThePreviousDeviceChangeNothingAfterTheNextSetup() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let previous = FakeDevice(location: nil)
        let stores = Self.deviceStores(model, on: previous)
        await Self.deviceWorkSettled(model)

        model.connect()
        await commands.waitUntilReached()
        previous.storeListeners.reportAll()
        previous.reportControllerListeners()
        stores.reset()
        let next = FakeDevice(location: nil)
        stores.setup(next, localState: nil)
        // the setup's own calls
        next.forgetMainThreadCalls()
        next.forgetControllerMainThreadCalls()
        // the previous device's listeners, still closing, report again
        previous.storeListeners.reportAll()
        await Self.mainQueueDrained()
        #expect(stores.transportSettingsStore.settings(.client) == nil)
        #expect(stores.transportSettingsStore.status(.client) == nil)
        #expect(!stores.networkPeersStore.peersAvailable)
        #expect(next.mainThreadCalls == [])
        #expect(next.controllerMainThreadCalls == [])

        commands.release()
        await Self.deviceWorkSettled(model)
        #expect(previous.storeListeners.count == 0)
        stores.reset()
        await Self.deviceWorkSettled(model)
        #expect(next.storeListeners.count == 0)
    }

    // MARK: showing the window while a command is held

    /// The window's setup as NetworkApp makes it once the commands have run
    /// (DeferredWindowSetup): the controller, the view model, the stores.
    /// Counts the setups, and whether a command was pending at each.
    @MainActor
    final class WindowSetupRecord {
        private(set) var setups = 0
        private(set) var pendingAtSetup: [Bool] = []

        func setup(_ model: ConnectViewModel, _ commands: HeldCommands, _ device: FakeDevice, _ stores: DeviceStores) {
            setups += 1
            pendingAtSetup.append(model.hasPendingConnectCommands)
            model.readConnectionStatus = { commands.status }
            model.setup(api: nil, device: device, connectViewController: device.openConnectViewController())
            stores.setup(device, localState: nil)
        }
    }

    /// Showing the window (macOS) or foregrounding the app (iOS) right after
    /// a menu bar or widget connect: the setup opened the window's controller,
    /// added its listeners and read the device on the main actor, and with
    /// the connect held in the sdk each of those waited on the device's state
    /// lock, which the command keeps through its rpc, up to the 60 s rpc
    /// timeout. Now the view model stays suspended, showing the tap's state,
    /// and the setup runs once the command has returned.
    @Test func showingTheWindowWhileACommandIsHeldDefersTheSetup() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        let stores = DeviceStores(deviceWorkQueue: model.connectCommandQueue)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)

        model.connect()
        await commands.waitUntilReached()
        device.forgetMainThreadCalls()
        let windowSetup = DeferredWindowSetup()
        let record = WindowSetupRecord()
        // as NetworkApp.updateConnectViewModel applies the window showing
        let setup = windowSetup.schedule(model, stillWanted: { true }) {
            record.setup(model, commands, device, stores)
        }
        await Self.mainQueueDrained()
        #expect(record.setups == 0)
        #expect(device.mainThreadCalls == [])
        #expect(device.controllers.isEmpty)
        #expect(model.connectionStatus == .destinationSet)

        commands.release()
        await setup.value
        #expect(record.setups == 1)
        #expect(record.pendingAtSetup == [false])
        #expect(model.connectViewController != nil)
        #expect(device.controllers.count == 3)
        stores.reset()
        await Self.deviceWorkSettled(model)
    }

    /// A hide, a reset or another device before the commands have run
    /// retires the setup (its token): it never runs, and nor does one that
    /// is no longer wanted when they have.
    @Test func aRetiredOrUnwantedSetupNeverRuns() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        let stores = DeviceStores(deviceWorkQueue: model.connectCommandQueue)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        let windowSetup = DeferredWindowSetup()
        let record = WindowSetupRecord()

        model.connect()
        await commands.waitUntilReached()
        // shown, then hidden again
        let hidden = windowSetup.schedule(model, stillWanted: { true }) {
            record.setup(model, commands, device, stores)
        }
        windowSetup.cancel()
        // shown on a device, then on the next one: only the newest runs
        let replaced = windowSetup.schedule(model, stillWanted: { true }) {
            record.setup(model, commands, device, stores)
        }
        let next = FakeDevice(location: nil)
        var nextSetups = 0
        let newest = windowSetup.schedule(model, stillWanted: { true }) {
            nextSetups += 1
        }
        commands.release()
        await hidden.value
        await replaced.value
        await newest.value
        #expect(record.setups == 0)
        #expect(nextSetups == 1)
        #expect(device.mainThreadCalls.filter { $0 == "openConnectViewController" } == [])

        // no longer wanted once the commands have run: the window went
        // inactive or the device changed without a new update
        let unwanted = windowSetup.schedule(model, stillWanted: { false }) {
            record.setup(model, commands, next, stores)
        }
        await unwanted.value
        #expect(record.setups == 0)
        #expect(next.mainThreadCalls == [])
    }

    /// A tap made while the setup waits queues a command the setup would
    /// wait on again: the setup checks just before it runs and waits for
    /// that one too. The tap shows its state meanwhile.
    @Test func aTapDuringTheWaitIsWaitedForBeforeTheSetup() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        let stores = DeviceStores(deviceWorkQueue: model.connectCommandQueue)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        let windowSetup = DeferredWindowSetup()
        let record = WindowSetupRecord()

        model.connect()
        await commands.waitUntilReached()
        let setup = windowSetup.schedule(model, stillWanted: { true }) {
            record.setup(model, commands, device, stores)
        }
        // the setup is waiting on the connect
        await Self.mainQueueDrained()
        model.disconnect()
        #expect(model.connectionStatus == .disconnected)

        commands.release()
        await commands.waitUntilReached()
        await Self.mainQueueDrained()
        // the connect has returned, the disconnect is held
        #expect(record.setups == 0)
        #expect(model.connectionStatus == .disconnected)
        #expect(device.mainThreadCalls.filter { $0 == "openConnectViewController" } == [])

        commands.release()
        await setup.value
        #expect(record.setups == 1)
        #expect(record.pendingAtSetup == [false])
        #expect(commands.performed == [.connectBestAvailable, .disconnect])
        stores.reset()
        await Self.deviceWorkSettled(model)
    }

    /// Taps that keep coming hold the setup back at most `retryLimit` more
    /// waits; then it runs, as it did before the wait.
    @Test func theSetupRunsAfterAtMostTheRetryLimit() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        let stores = DeviceStores(deviceWorkQueue: model.connectCommandQueue)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        let windowSetup = DeferredWindowSetup()
        let record = WindowSetupRecord()

        model.connect()
        await commands.waitUntilReached()
        let setup = windowSetup.schedule(model, stillWanted: { true }) {
            record.setup(model, commands, device, stores)
        }
        await Self.mainQueueDrained()
        for round in 0...DeferredWindowSetup.retryLimit {
            // a tap during each wait
            if round % 2 == 0 {
                model.disconnect()
            } else {
                model.connect()
            }
            commands.release()
            await commands.waitUntilReached()
            await Self.mainQueueDrained()
            #expect(record.setups == (round < DeferredWindowSetup.retryLimit ? 0 : 1), "round \(round)")
        }
        await setup.value
        #expect(record.pendingAtSetup == [true])

        commands.release()
        await Self.deviceWorkSettled(model)
        stores.reset()
        await Self.deviceWorkSettled(model)
    }

    // MARK: the menu bar while suspended

    #if os(macOS)
    /// The menu bar's row and icon for `model`, as NetworkApp shows them.
    private static func menuBar(_ model: ConnectViewModel) -> MenuBarConnectionState {
        MenuBarConnectionState(
            model.connectionStatus,
            fromLocation: model.connectionStatusFromLocation,
            tunnelConnected: model.tunnelConnected
        )
    }

    /// Hiding the window (Cmd-Q, close, minimize, occlusion, a hidden
    /// launch) keeps what the window last showed while the location is the
    /// same and the tunnel up: connected stays ✓ Connected, as it did before
    /// the menu bar learned to say Connecting, and failed and disconnected
    /// stay what they were. A connect still in progress has nothing left to
    /// report its end, so it reads as the location's: connected with the
    /// tunnel up, not "Connecting…" for as long as the window stays hidden.
    @Test func suspendedMenuBarKeepsWhatTheWindowLastShowed() async {
        let cases: [(status: ConnectionStatus, located: Bool, shown: MenuBarConnectionState, hidden: MenuBarConnectionState)] = [
            (status: .connected, located: true, shown: .connected, hidden: .connected),
            (status: .connecting, located: true, shown: .connecting, hidden: .connected),
            (status: .destinationSet, located: true, shown: .connecting, hidden: .connected),
            (status: .connectFailed, located: true, shown: .failed, hidden: .failed),
            (status: .disconnected, located: false, shown: .disconnected, hidden: .disconnected),
        ]
        for c in cases {
            let commands = HeldCommands(status: c.status)
            let model = Self.model(commands)
            model.tunnelConnected = true
            let device = FakeDevice(location: c.located ? Self.location(bestAvailable: false) : nil, tunnelStarted: true)
            #expect(Self.menuBar(model) == c.shown, "\(c.status) shown")
            model.suspend(api: nil, device: device)
            model.readConnectionStatus = { nil }
            await Self.deviceWorkSettled(model)
            #expect(Self.menuBar(model) == c.hidden, "\(c.status) hidden")
        }
    }

    /// The tunnel stops while the window is hidden (its listener stays
    /// open): a kept CONNECTED says what the main window says there, and a
    /// connection from the location alone reads as connecting.
    @Test func suspendedMenuBarFollowsTheTunnel() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: Self.location(bestAvailable: false), tunnelStarted: true)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        #expect(Self.menuBar(model) == .connected)

        device.reportTunnel(false)
        await Self.mainQueueDrained()
        #expect(Self.menuBar(model) == .tunnelDisconnected)

        // another location, still no tunnel
        device.reportLocation(Self.location(bestAvailable: true))
        await Self.mainQueueDrained()
        #expect(Self.menuBar(model) == .connecting)
        device.reportTunnel(true)
        await Self.mainQueueDrained()
        #expect(Self.menuBar(model) == .connected)
    }

    /// While hidden, the same location reported again changes nothing. A
    /// new location, moved by another surface, has no controller to say how
    /// far it got and reads as connected, as it always did; no location
    /// reads as disconnected.
    @Test func suspendedMenuBarFollowsTheLocationOnceItChanges() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: Self.location(bestAvailable: false), tunnelStarted: true)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        #expect(Self.menuBar(model) == .connected)

        device.reportLocation(Self.location(bestAvailable: false))
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .connected)
        #expect(Self.menuBar(model) == .connected)

        device.reportLocation(Self.location(bestAvailable: true))
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .destinationSet)
        #expect(model.connectionStatusFromLocation)
        #expect(Self.menuBar(model) == .connected)

        device.reportLocation(nil)
        await Self.mainQueueDrained()
        #expect(Self.menuBar(model) == .disconnected)
    }

    /// The menu bar's Connect with the window hidden: connecting while the
    /// command is held and until the tunnel starts, connected then. A tunnel
    /// that never starts (the vpn permission or the system extension not
    /// approved) stays connecting. Shown again, the window's controller says
    /// how far it got.
    @Test func suspendedMenuBarConnectReadsAsConnectedOnceItReturns() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        await Self.deviceWorkSettled(model)
        #expect(Self.menuBar(model) == .disconnected)

        model.connect()
        #expect(Self.menuBar(model) == .connecting)
        await commands.waitUntilReached()
        #expect(Self.menuBar(model) == .connecting)
        commands.release()
        await model.connectCommandsSettled()
        #expect(Self.menuBar(model) == .connecting)
        device.reportLocation(Self.location(bestAvailable: true))
        await Self.mainQueueDrained()
        #expect(Self.menuBar(model) == .connecting)
        device.reportTunnel(true)
        await Self.mainQueueDrained()
        #expect(Self.menuBar(model) == .connected)

        // the controller reports the same DESTINATION_SET: now it is its own
        model.readConnectionStatus = { commands.status }
        model.setup(api: nil, device: device, connectViewController: nil)
        #expect(model.connectionStatus == .destinationSet)
        #expect(!model.connectionStatusFromLocation)
        #expect(Self.menuBar(model) == .connecting)
    }
    #endif

    /// Signed out (or the device went away) while a connect is held: the
    /// status is cleared at once, not held by the signed out account's tap,
    /// and the connect still runs to the end.
    @Test func resetWhileAConnectIsHeldClearsTheStatus() async {
        let commands = HeldCommands()
        let model = Self.model(commands)

        model.connect()
        await commands.waitUntilReached()
        #expect(model.connectionStatus == .destinationSet)
        model.reset()
        // no controller after a reset
        model.readConnectionStatus = { nil }
        #expect(model.connectionStatus == nil)

        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.connectBestAvailable])
        #expect(model.connectionStatus == nil)
    }

    /// A connect of the signed out account still held when the next one
    /// signs in is not that account's connection: its start goes through
    /// the gate, and out of balance it is refused.
    @Test func aConnectHeldAcrossSignOutIsNotTheNextAccountsConnection() async {
        let commands = HeldCommands()
        let model = Self.model(commands)

        model.connect()
        await commands.waitUntilReached()
        model.reset()

        // the next account, out of balance, with its own controller
        model.loadCachedBalance = { Self.balance(0) }
        model.readConnectionStatus = { ConnectionStatus.disconnected.rawValue }
        model.setup(api: nil, device: FakeDevice(location: nil), connectViewController: nil)
        #expect(model.connectionStatus == .disconnected)

        model.connect()
        #expect(model.isPresentedUpgradeSheet)
        #expect(model.connectionStatus == .disconnected)

        // the second release lets a start admitted by mistake return too,
        // so the test fails on it rather than waiting for it
        commands.release()
        commands.release()
        await model.connectCommandsSettled()
        // only the signed out account's connect reached the sdk
        #expect(commands.performed == [.connectBestAvailable])
        #expect(model.connectionStatus == .disconnected)
    }

    // MARK: the device going away

    /// No device is a reset, whatever the window state; with a device, a
    /// hidden presentation suspends and a shown one sets up once.
    @Test func noDeviceResetsWhateverTheWindowState() {
        for presentationActive in [false, true] {
            for presentsDevice in [false, true] {
                #expect(ConnectViewModelUpdate.next(
                    hasDevice: false,
                    presentationActive: presentationActive,
                    presentsDevice: presentsDevice
                ) == .reset, "active \(presentationActive)")
            }
        }
        #expect(ConnectViewModelUpdate.next(hasDevice: true, presentationActive: false, presentsDevice: false) == .suspend)
        #expect(ConnectViewModelUpdate.next(hasDevice: true, presentationActive: false, presentsDevice: true) == .suspend)
        #expect(ConnectViewModelUpdate.next(hasDevice: true, presentationActive: true, presentsDevice: false) == .setup)
        #expect(ConnectViewModelUpdate.next(hasDevice: true, presentationActive: true, presentsDevice: true) == .unchanged)
    }

    /// The device goes away (a sign out, the server's or the account
    /// deletion's) with the window hidden while a start waits on its
    /// balance: the view model is reset as NetworkApp applies the update,
    /// and the balance arriving afterwards connects nothing.
    @Test func theDeviceGoingAwayWhileHiddenResetsTheViewModel() async {
        let commands = HeldCommands()
        let fetch = HeldFetch()
        let model = Self.model(commands, cached: Self.balance(Self.gib, age: 30 * 60), fetch: fetch)
        model.suspend(api: nil, device: FakeDevice(location: nil))
        model.readConnectionStatus = { nil }

        model.connect()
        await fetch.waitUntilStarted()
        #expect(model.connectionStatus == .destinationSet)
        let start = model.startConnectTask

        // as NetworkApp.updateConnectViewModel applies it
        switch ConnectViewModelUpdate.next(hasDevice: false, presentationActive: false, presentsDevice: false) {
        case .reset:
            model.reset()
        case .suspend, .setup, .unchanged:
            model.suspend(api: nil, device: nil)
        }
        #expect(model.connectionStatus == nil)
        #expect(model.startConnectTask == nil)

        fetch.complete(Self.balance(Self.gib))
        await start?.value
        // lets a start that connects by mistake return, so the test fails on
        // it rather than waiting for it
        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed.isEmpty)
        #expect(model.connectionStatus == nil)
    }

    // MARK: signing out

    /// The provider list's writes of the location it connects, as the local
    /// state would get them. Safe for concurrent use.
    final class SavedLocations: @unchecked Sendable {
        private let stateLock = NSLock()
        private var savedLocations: [SdkConnectLocation] = []

        func save(_ location: SdkConnectLocation) {
            stateLock.withLock { savedLocations.append(location) }
        }

        var saved: [SdkConnectLocation] {
            stateLock.withLock { savedLocations }
        }
    }

    /// Connect tapped while the sign out's disconnect is held. Queued behind
    /// the sign out's wait, it ran beside the logout and saved its location
    /// in the network space, which outlives the sign out: the next sign-in
    /// reconnected there, already connected to the gate. Now every connect is
    /// refused from the moment the sign out starts.
    @Test func aConnectTappedDuringSignOutNeverReachesTheSdk() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        model.setup(api: nil, device: FakeDevice(location: nil), connectViewController: nil)
        let locations = SavedLocations()
        model.saveConnectLocation = { _, location in locations.save(location) }

        model.beginSignOut()
        #expect(model.connectionStatus == .disconnected)
        await commands.waitUntilReached()

        // the provider list, the connect button, best available, a restore
        model.connect(SdkConnectLocation())
        model.connect()
        model.connectBestAvailable()
        model.restoreConnect(onDevice: model.device)
        #expect(model.connectionStatus == .disconnected)
        #expect(model.startConnectTask == nil)
        #expect(!model.isPresentedUpgradeSheet)

        // the extra releases let connects admitted by mistake return too, so
        // the test fails on them rather than waiting for them
        for _ in 0..<5 {
            commands.release()
        }
        await model.connectCommandsSettled()
        #expect(commands.performed == [.disconnect])
        #expect(locations.saved.isEmpty)

        // the reset once the device is gone ends the sign out
        #expect(model.signingOut)
        model.reset()
        #expect(!model.signingOut)
    }

    /// The server signs the account out while its connect is inside the
    /// sdk, with another connect and a disconnect queued behind it. The held
    /// connect returns but skips its write of the location, the queued one
    /// never reaches the sdk, and the disconnect still runs.
    @Test func aServerSignOutMidCommandSkipsTheAccountsConnects() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let locations = SavedLocations()
        model.saveConnectLocation = { _, location in locations.save(location) }
        let held = SdkConnectLocation()
        let queued = SdkConnectLocation()
        let device = FakeDevice(location: nil)
        model.setup(api: nil, device: device, connectViewController: nil)

        model.connect(held)
        await commands.waitUntilReached()
        model.connect(queued)
        model.disconnect()

        // the device manager begins the logout, then the device goes away
        model.signOutStarted(device: device)
        model.reset()
        model.readConnectionStatus = { nil }

        for _ in 0..<3 {
            commands.release()
        }
        await model.connectCommandsSettled()
        #expect(commands.performed == [.connect(held), .disconnect])
        #expect(locations.saved.isEmpty)
        #expect(model.connectionStatus == nil)
    }

    /// The macOS purchase flow restores the connection it dropped for the
    /// store only on the device it dropped it on. An account that changed
    /// while the store was open never asked for it, and the restore, which
    /// is not a start, connected it past its gate.
    @Test func theRestoreAfterAPurchaseIsOnlyForTheSameDevice() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let purchaseDevice = FakeDevice(location: nil)
        model.setup(api: nil, device: purchaseDevice, connectViewController: nil)

        // signed out and in while the store was open
        model.reset()
        model.readConnectionStatus = { ConnectionStatus.disconnected.rawValue }
        model.setup(api: nil, device: FakeDevice(location: nil), connectViewController: nil)
        model.restoreConnect(onDevice: purchaseDevice)
        #expect(model.connectionStatus == .disconnected)
        // lets a restore made by mistake return, so the test fails on it
        // rather than waiting for it
        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed.isEmpty)

        // on the same device the restore connects
        model.restoreConnect(onDevice: model.device)
        #expect(model.connectionStatus == .destinationSet)
        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.connectBestAvailable])
    }

    /// A logout with no device (a second one, or the account deletion's
    /// after a server sign out) starts no sign out: no device change would
    /// ever end it, and the next account's connects were dropped.
    @Test func aLogoutWithNoDeviceStartsNoSignOut() {
        let manager = DeviceManager(startupMode: .production, automaticallyInitialize: false)
        var started = 0
        manager.logoutStarted = { _ in
            started += 1
        }
        #expect(manager.device == nil)
        #expect(manager.beginLogout())
        #expect(started == 0)
    }

    /// A sign out that never reached a reset (its logout found no device to
    /// clear): the next sign-in's setup ends it, and that account connects.
    @Test func theNextAccountConnectsAfterASignOutThatNeverReset() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        model.setup(api: nil, device: FakeDevice(location: nil), connectViewController: nil)
        model.beginSignOut()
        commands.release()
        await model.connectCommandsSettled()
        #expect(model.signingOut)

        // the next account, with no reset in between
        model.readConnectionStatus = { ConnectionStatus.disconnected.rawValue }
        model.setup(api: nil, device: FakeDevice(location: nil), connectViewController: nil)
        #expect(!model.signingOut)
        model.connect()
        #expect(model.connectionStatus == .destinationSet)
        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.disconnect, .connectBestAvailable])

        // and suspending on another device ends one the same way
        model.signOutStarted(device: model.device)
        model.suspend(api: nil, device: FakeDevice(location: nil))
        #expect(!model.signingOut)
    }

    /// Sign out twice while the first one's disconnect is held: the first
    /// signs the account out, and the next account signs in before the
    /// second one's wait returns. The second does not sign that account out.
    @Test func aStaleSecondSignOutDoesNotSignOutTheNextAccount() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let first = FakeDevice(location: nil)
        model.setup(api: nil, device: first, connectViewController: nil)
        var current: SdkDeviceRemote? = first
        var logouts = 0
        let logout = {
            logouts += 1
            current = nil
        }

        let firstSignOut = Task { await model.signOut(currentDevice: { current }, logout: logout) }
        await commands.waitUntilReached()
        // the second click reads the device before the first one finishes
        var secondClicked: CheckedContinuation<Void, Never>?
        let secondSignOut = Task {
            await model.signOut(
                currentDevice: {
                    secondClicked?.resume()
                    secondClicked = nil
                    return current
                },
                logout: logout
            )
        }
        await withCheckedContinuation { secondClicked = $0 }

        commands.release()
        await firstSignOut.value
        #expect(logouts == 1)
        // the device went away, and the next account signed in
        model.reset()
        let next = FakeDevice(location: nil)
        current = next
        model.setup(api: nil, device: next, connectViewController: nil)

        commands.release()
        await secondSignOut.value
        #expect(logouts == 1)
        #expect(current === next)
    }
}
