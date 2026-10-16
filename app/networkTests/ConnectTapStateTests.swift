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
    /// `location`, and `reportLocation` calls its location listener as the
    /// sdk's event does, which reaches the app after the command returns.
    /// Every call the view model makes on a device is answered here, so
    /// nothing reaches the Go side. Safe for concurrent use.
    final class FakeDevice: SdkDeviceRemote, @unchecked Sendable {
        private let stateLock = NSLock()
        private var location: SdkConnectLocation?
        private var locationListener: SdkConnectLocationChangeListenerProtocol?

        init(location: SdkConnectLocation?) {
            self.location = location
            super.init(ref: NSObject())
        }

        /// The device's location changed and the sdk reports it.
        func reportLocation(_ location: SdkConnectLocation?) {
            let listener = stateLock.withLock {
                self.location = location
                return locationListener
            }
            listener?.connectLocationChanged(location)
        }

        var hasLocationListener: Bool {
            stateLock.withLock { locationListener != nil }
        }

        override func getConnectLocation() -> SdkConnectLocation? {
            stateLock.withLock { location }
        }

        override func getDefaultLocation() -> SdkConnectLocation? {
            nil
        }

        override func getTunnelStarted() -> Bool {
            false
        }

        override func getContractStatus() -> SdkContractStatus? {
            nil
        }

        override func add(_ listener: SdkConnectLocationChangeListenerProtocol?) -> SdkSubProtocol? {
            stateLock.withLock { locationListener = listener }
            return FakeSub { [weak self] in
                self?.stateLock.withLock { self?.locationListener = nil }
            }
        }

        override func add(_ listener: SdkTunnelChangeListenerProtocol?) -> SdkSubProtocol? {
            FakeSub {}
        }

        override func add(_ listener: SdkContractStatusChangeListenerProtocol?) -> SdkSubProtocol? {
            FakeSub {}
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

    /// The macOS menu bar's Disconnect with the window hidden (suspended):
    /// the status follows the device's location, and the sdk reports the
    /// disconnect only after the command returns. The view keeps the tap's
    /// state through the return instead of going back to the location read
    /// before the command.
    @Test func suspendedDisconnectNeverFlipsBackToTheOldLocation() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: SdkConnectLocation())
        let record = Self.record(model)

        model.disconnect()
        await commands.waitUntilReached()
        // the window hides while the extension holds the disconnect: the
        // device still reports the location, and no controller is presented
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        #expect(device.hasLocationListener)
        #expect(model.connectionStatus == .disconnected)

        commands.release()
        await model.connectCommandsSettled()
        #expect(commands.performed == [.disconnect])
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
    /// the device's location listener is closed, and once the connect
    /// returns the status is read from the controller again.
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
        #expect(!device.hasLocationListener)
        #expect(model.connectionStatus == .destinationSet)

        // the controller already reports connected when the connect returns
        commands.statusAfterCommand = .connected
        commands.release()
        await model.connectCommandsSettled()
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
        #expect(model.connectionStatus == .disconnected)
        device.reportLocation(SdkConnectLocation())
        await Self.mainQueueDrained()
        #expect(model.connectionStatus == .destinationSet)

        model.readConnectionStatus = { commands.status }
        model.setup(api: nil, device: device, connectViewController: nil)
        #expect(model.connectionStatus == .connected)
    }

    // MARK: the menu bar while suspended

    #if os(macOS)
    /// The menu bar's row and icon for `model`, as NetworkApp shows them.
    private static func menuBar(_ model: ConnectViewModel) -> MenuBarConnectionState {
        MenuBarConnectionState(model.connectionStatus, fromLocation: model.connectionStatusFromLocation)
    }

    /// A location with an id: two of them are the same location when their
    /// ids are.
    private static func location(bestAvailable: Bool) -> SdkConnectLocation {
        let id = SdkConnectLocationId()
        id.bestAvailable = bestAvailable
        let location = SdkConnectLocation()
        location.connectLocationId = id
        return location
    }

    /// Hiding the window (Cmd-Q, close, minimize, occlusion, a hidden
    /// launch) keeps what the window last showed while the location is the
    /// same: connected stays ✓ Connected, as it did before the menu bar
    /// learned to say Connecting, and connecting, failed and disconnected
    /// stay what they were.
    @Test func suspendedMenuBarKeepsWhatTheWindowLastShowed() {
        let cases: [(status: ConnectionStatus, located: Bool, menuBar: MenuBarConnectionState)] = [
            (status: .connected, located: true, menuBar: .connected),
            (status: .connecting, located: true, menuBar: .connecting),
            (status: .destinationSet, located: true, menuBar: .connecting),
            (status: .connectFailed, located: true, menuBar: .failed),
            (status: .disconnected, located: false, menuBar: .disconnected),
        ]
        for c in cases {
            let commands = HeldCommands(status: c.status)
            let model = Self.model(commands)
            let device = FakeDevice(location: c.located ? Self.location(bestAvailable: false) : nil)
            #expect(Self.menuBar(model) == c.menuBar, "\(c.status) shown")
            model.suspend(api: nil, device: device)
            model.readConnectionStatus = { nil }
            #expect(model.connectionStatus == c.status, "\(c.status) hidden")
            #expect(Self.menuBar(model) == c.menuBar, "\(c.status) hidden")
        }
    }

    /// While hidden, the same location reported again changes nothing. A
    /// new location, moved by another surface, has no controller to say how
    /// far it got and reads as connected, as it always did; no location
    /// reads as disconnected.
    @Test func suspendedMenuBarFollowsTheLocationOnceItChanges() async {
        let commands = HeldCommands(status: .connected)
        let model = Self.model(commands)
        let device = FakeDevice(location: Self.location(bestAvailable: false))
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
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
    /// command is held, connected once it has returned. Shown again, the
    /// window's controller says how far it got.
    @Test func suspendedMenuBarConnectReadsAsConnectedOnceItReturns() async {
        let commands = HeldCommands()
        let model = Self.model(commands)
        let device = FakeDevice(location: nil)
        model.suspend(api: nil, device: device)
        model.readConnectionStatus = { nil }
        #expect(Self.menuBar(model) == .disconnected)

        model.connect()
        #expect(Self.menuBar(model) == .connecting)
        await commands.waitUntilReached()
        #expect(Self.menuBar(model) == .connecting)
        commands.release()
        await model.connectCommandsSettled()
        #expect(Self.menuBar(model) == .connected)
        device.reportLocation(Self.location(bestAvailable: true))
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
        let locations = SavedLocations()
        model.saveConnectLocation = { _, location in locations.save(location) }

        model.beginSignOut()
        #expect(model.connectionStatus == .disconnected)
        await commands.waitUntilReached()

        // the provider list, the connect button, best available, a restore
        model.connect(SdkConnectLocation())
        model.connect()
        model.connectBestAvailable()
        model.restoreConnect()
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

        model.connect(held)
        await commands.waitUntilReached()
        model.connect(queued)
        model.disconnect()

        // the device manager begins the logout, then the device goes away
        model.signOutStarted()
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

    /// Every logout, whoever starts it, tells the connect view model first.
    @Test func everyLogoutStartsTheSignOutOnce() {
        let manager = DeviceManager(startupMode: .production, automaticallyInitialize: false)
        var started = 0
        manager.logoutStarted = {
            started += 1
        }
        #expect(manager.beginLogout())
        #expect(started == 1)
        #expect(!manager.beginLogout())
        #expect(started == 1)
    }
}
