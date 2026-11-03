import Foundation
import SwiftUI
import Testing
import URnetworkSdk
@testable import URnetwork

/// The macOS purchase flow (ConnectViewModel.purchaseAroundConnection, which
/// every surface's purchase goes through by ConnectionAwareSubscriptionStore).
/// It drops the connection for the store, so it tells the user first, and only
/// a connection the user requested is dropped and brought back: the rpc link to
/// the extension is up with none requested too, while providing or with the
/// kill switch on, and bringing "it" back started a connection nobody asked for.
///
/// The store, the sdk's commands and the notice are fakes, and the view model
/// the real one; `purchaseDropsConnection` stands in for the platform, so this
/// runs the same on macOS and on the iOS simulator. Nothing waits on time.
@MainActor
@Suite(.serialized)
struct PurchaseAroundConnectionTests {

    /// What reached the user, the sdk and the store, in order. Safe for
    /// concurrent use: the sdk's commands run off the main actor.
    final class Events: @unchecked Sendable {
        private let stateLock = NSLock()
        private var values: [String] = []

        func append(_ event: String) {
            stateLock.withLock { values.append(event) }
        }

        var all: [String] {
            stateLock.withLock { values }
        }
    }

    /// The status the sdk's controller reports. Safe for concurrent use.
    final class SdkStatus: @unchecked Sendable {
        private let stateLock = NSLock()
        private var value: ConnectionStatus?

        init(_ value: ConnectionStatus?) {
            self.value = value
        }

        var rawValue: String? {
            get { stateLock.withLock { value?.rawValue } }
            set { stateLock.withLock { value = newValue.flatMap(ConnectionStatus.init(rawValue:)) } }
        }
    }

    /// A store that records when it opens, and runs `whileOpen` before it returns.
    final class FakeStore: SubscriptionStore {
        let events: Events
        var whileOpen: (() async -> Void)?

        init(events: Events) {
            self.events = events
        }

        func purchase(plan: PaymentOption, onSuccess: @escaping () -> Void) async {
            events.append("store \(plan)")
            await whileOpen?()
        }

        func redeemOffer(_ offer: PlanOffer, onSuccess: @escaping () -> Void) async {
            events.append("store offer")
            await whileOpen?()
        }

        var storeName: String { "fake" }
        var distribution: BillingDistribution { .direct }
        func presentation(tier: PlanTier?, offer: PlanOffer?, storefrontCountryName: String?) -> PlanPresentation? { nil }
        var plansLoadFailed: Bool { true }
        var retriedCountry: String?
        func retryLoadPlansIfNeeded(storefrontCountry: String?) { retriedCountry = storefrontCountry }
        var isPurchasing: Bool { true }
        var purchaseSuccess: Bool { true }
        var purchasePending: Bool { true }
        var purchaseError: String? { "error" }
        var purchaseConfirmingTitle: String? { "title" }
        var purchaseConfirmingMessage: String? { "message" }
        var checkoutView: AnyView? { AnyView(EmptyView()) }
        var resetCount = 0
        func resetPurchaseState() { resetCount += 1 }
        func restorePurchases() async -> RestorePurchasesOutcome { .nothingToRestore }
        var isRestoringPurchases: Bool { true }
        var restoreResultMessage: String? { "restored" }
    }

    /// The view model on a fake device with the sdk's status read, the store
    /// behind the surfaces' store, and what happened to them.
    @MainActor
    struct Flow {
        let model: ConnectViewModel
        let store: FakeStore
        let buying: ConnectionAwareSubscriptionStore
        let events: Events

        /// What a surface does, then the restore's command has run.
        func buy() async {
            await buying.purchase(plan: .yearly, onSuccess: {})
            await model.connectCommandsSettled()
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let offer = PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), appleOfferCode: "WELCOME")

    /// A macOS flow with the sdk's controller reporting `status`, the device's
    /// rpc link `rpcUp`, and the user answering the notice `answer`. The balance
    /// is funded and fresh. Commands take effect at once unless `commands` holds
    /// them.
    private static func flow(
        status: ConnectionStatus?,
        rpcUp: Bool,
        answer: Bool = true,
        commands: ConnectTapStateTests.HeldCommands? = nil
    ) -> Flow {
        let events = Events()
        let sdkStatus = SdkStatus(status)
        let model = ConnectViewModel()
        model.purchaseDropsConnection = true
        model.now = { now }
        model.loadCachedBalance = {
            WidgetBalanceSnapshot(
                updatedAt: now,
                startBalanceByteCount: 1024,
                balanceByteCount: 1024,
                openTransferByteCount: 0,
                isPro: false
            )
        }
        model.performConnectCommand = { command, _, _ in
            commands?.perform(command)
            events.append(command == .disconnect ? "disconnect" : "connect")
            sdkStatus.rawValue = command.startStatus.rawValue
        }
        model.readConnectionStatus = { sdkStatus.rawValue }
        model.confirmPurchaseDisconnect = {
            events.append("notice")
            return answer
        }
        let device = ConnectTapStateTests.FakeDevice(location: nil)
        device.remoteConnected = rpcUp
        model.setup(api: nil, device: device, connectViewController: nil)
        let store = FakeStore(events: events)
        return Flow(
            model: model,
            store: store,
            buying: ConnectionAwareSubscriptionStore(store: store, connection: model),
            events: events
        )
    }

    // MARK: the notice

    /// The reported gap: the connection dropped with nothing said. The user
    /// is asked while the connection still stands, and the store opens after
    /// the disconnect; the connection comes back once the store returns.
    @Test func aRequestedConnectionIsToldBeforeItDrops() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        var statusAtTheNotice: ConnectionStatus?
        var commandsAtTheNotice: [String] = []
        flow.model.confirmPurchaseDisconnect = { [model = flow.model, events = flow.events] in
            statusAtTheNotice = model.connectionStatus
            commandsAtTheNotice = events.all
            events.append("notice")
            return true
        }

        await flow.buy()

        #expect(statusAtTheNotice == .connected)
        #expect(commandsAtTheNotice.isEmpty)
        #expect(flow.events.all == ["notice", "disconnect", "store yearly", "connect"])
        #expect(flow.model.connectionStatus == .destinationSet)
    }

    /// Whatever the rpc link says: a connection can be requested with the
    /// extension not up, and the purchase still drops it.
    @Test func everyRequestedStatusIsToldWithOrWithoutTheRpcLink() async {
        for status in [ConnectionStatus.connecting, .destinationSet, .connected, .connectFailed] {
            for rpcUp in [true, false] {
                let flow = Self.flow(status: status, rpcUp: rpcUp)
                await flow.buy()
                #expect(
                    flow.events.all == ["notice", "disconnect", "store yearly", "connect"],
                    "\(status) rpcUp \(rpcUp)"
                )
            }
        }
    }

    /// The notice offers a way out: the connection stands and nothing is bought.
    @Test func cancellingTheNoticeKeepsTheConnectionAndBuysNothing() async {
        let flow = Self.flow(status: .connected, rpcUp: true, answer: false)
        await flow.buy()
        #expect(flow.events.all == ["notice"])
        #expect(flow.model.connectionStatus == .connected)

        // and the next try asks again
        await flow.buy()
        #expect(flow.events.all == ["notice", "notice"])
    }

    /// The welcome offer is a purchase too.
    @Test func theOfferGoesThroughTheSameFlow() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        await flow.buying.redeemOffer(Self.offer, onSuccess: {})
        await flow.model.connectCommandsSettled()
        #expect(flow.events.all == ["notice", "disconnect", "store offer", "connect"])
    }

    // MARK: a connection nobody requested

    /// The flagged bug. Providing, or the kill switch, keeps the extension and
    /// its rpc link up with no connection requested. The flow read the link as a
    /// connection, so it "brought back" one nobody asked for: past the start
    /// gate (a restore is not a start), and under Auto with public providing
    /// turned on (the sdk's Connect), so a purchase changed what the device
    /// provides. Nothing reaches the sdk now, and nothing is said.
    @Test func aTunnelUpWithNoConnectionRequestedIsLeftAlone() async {
        let flow = Self.flow(status: .disconnected, rpcUp: true)
        await flow.buy()
        #expect(flow.events.all == ["store yearly"])
        #expect(flow.model.connectionStatus == .disconnected)
    }

    /// Not known yet is not requested: a connect from here would be a start.
    @Test func anUnknownStatusIsNotAConnection() async {
        let flow = Self.flow(status: nil, rpcUp: true)
        await flow.buy()
        #expect(flow.events.all == ["store yearly"])
    }

    /// A start refused for its balance is not a connection yet: it keeps waiting
    /// on the balance, which the purchase brings back, and no disconnect cancels
    /// it (the upgrade sheet this purchase comes from opened for it).
    @Test func aStartWaitingOnItsBalanceStaysWaiting() async {
        let flow = Self.flow(status: .disconnected, rpcUp: true)
        flow.model.loadCachedBalance = {
            WidgetBalanceSnapshot(
                updatedAt: Self.now,
                startBalanceByteCount: 1024,
                balanceByteCount: 0,
                openTransferByteCount: 0,
                isPro: false
            )
        }
        flow.model.connect()
        #expect(flow.model.isPresentedUpgradeSheet)
        #expect(flow.model.balanceRecoveryState.startWaiting)

        await flow.buy()

        #expect(flow.events.all == ["store yearly"])
        #expect(flow.model.balanceRecoveryState.startWaiting)
    }

    // MARK: taps the sdk has not finished

    /// The user's own disconnect, still in the sdk, is not a connection, and
    /// it reaches the sdk before the store opens, as the flow's own does.
    @Test func aDisconnectTapStillInTheSdkIsNotAConnection() async {
        let commands = ConnectTapStateTests.HeldCommands(status: .connected)
        let flow = Self.flow(status: .connected, rpcUp: true, commands: commands)
        flow.model.disconnect()
        await commands.waitUntilReached()

        let buying = Task { await flow.buy() }
        await Self.drainMain()
        #expect(flow.events.all.isEmpty)

        // the extra releases let a command made by mistake return too, so the
        // test fails on it rather than waiting for it
        for _ in 0..<3 {
            commands.release()
        }
        await buying.value
        #expect(flow.events.all == ["disconnect", "store yearly"])
    }

    /// A connect still in the sdk is what the user asked for. The disconnect
    /// queues behind it, and the store opens only once it has run.
    @Test func aConnectTapStillInTheSdkIsToldAndTheStoreWaitsForTheDisconnect() async {
        let commands = ConnectTapStateTests.HeldCommands(status: .disconnected)
        let flow = Self.flow(status: .disconnected, rpcUp: true, commands: commands)
        flow.model.connect()
        await commands.waitUntilReached()

        let buying = Task { await flow.buying.purchase(plan: .yearly, onSuccess: {}) }
        await Self.drainMain()
        #expect(flow.events.all == ["notice"])

        // the connect returns, and the disconnect is inside the sdk: no store yet
        commands.release()
        await commands.waitUntilReached()
        #expect(flow.events.all == ["notice", "connect"])

        // the disconnect returns: the store opens, returns, and the restore's
        // connect is inside the sdk
        commands.release()
        await commands.waitUntilReached()
        #expect(flow.events.all == ["notice", "connect", "disconnect", "store yearly"])

        commands.release()
        await buying.value
        await flow.model.connectCommandsSettled()
        #expect(commands.performed == [.connectBestAvailable, .disconnect, .connectBestAvailable])
    }

    // MARK: while the notice is up, and while the store is open

    /// The notice waits on the user. A disconnect made meanwhile (the menu bar)
    /// stands: the store opens, and nothing connects after it.
    @Test func aDisconnectWhileTheNoticeIsUpIsNotReconnected() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.model.confirmPurchaseDisconnect = { [model = flow.model, events = flow.events] in
            events.append("notice")
            model.disconnect()
            return true
        }
        await flow.buy()
        #expect(flow.events.all == ["notice", "disconnect", "store yearly"])
        #expect(flow.model.connectionStatus == .disconnected)
    }

    /// A sign out while the notice is up: the account that asked is gone, and
    /// the next one buys nothing and connects nothing because of it.
    @Test func anAccountChangingWhileTheNoticeIsUpBuysNothing() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.model.confirmPurchaseDisconnect = { [model = flow.model, events = flow.events] in
            events.append("notice")
            model.reset()
            model.setup(api: nil, device: ConnectTapStateTests.FakeDevice(location: nil), connectViewController: nil)
            return true
        }
        await flow.buy()
        #expect(flow.events.all == ["notice"])
    }

    /// A sign out that has started and has not finished yet is the same.
    @Test func aSignOutStartingWhileTheNoticeIsUpBuysNothing() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.model.confirmPurchaseDisconnect = { [model = flow.model, events = flow.events] in
            events.append("notice")
            model.signOutStarted(device: model.device)
            return true
        }
        await flow.buy()
        #expect(flow.events.all == ["notice"])
    }

    /// The restore is for the device it dropped the connection on.
    @Test func anAccountChangingWhileTheStoreIsOpenIsNotConnected() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.store.whileOpen = { [model = flow.model] in
            model.reset()
            model.setup(api: nil, device: ConnectTapStateTests.FakeDevice(location: nil), connectViewController: nil)
        }
        await flow.buy()
        #expect(flow.events.all == ["notice", "disconnect", "store yearly"])
    }

    /// A second tap while the store is open: the stores ignore it, and its
    /// restore ran at once, bringing the tunnel back under the open store.
    @Test func aSecondTapWhileTheFlowRunsDoesNothing() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        var tapped = false
        flow.store.whileOpen = { [buying = flow.buying] in
            guard !tapped else {
                return
            }
            tapped = true
            await buying.purchase(plan: .monthly, onSuccess: {})
        }
        await flow.buy()
        #expect(flow.events.all == ["notice", "disconnect", "store yearly", "connect"])
    }

    // MARK: the platform and the stores

    /// iOS keeps the connection: App Store traffic does not ride the tunnel
    /// there, so nothing is dropped and there is nothing to tell (the A6 note on
    /// AppStoreSubscriptionManager.purchase).
    @Test func withoutTheDropThereIsNoNoticeAndNoDisconnect() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.model.purchaseDropsConnection = false
        await flow.buy()
        #expect(flow.events.all == ["store yearly"])
        #expect(flow.model.connectionStatus == .connected)
    }

    /// A surface gets its store from the factory, so neither store can be bought
    /// from past the flow. Neither sells here, the manager with no network and the
    /// client with no server: both refuse after the flow's notice and disconnect.
    @Test func bothStoresTheFactoryMakesGoThroughTheFlow() async {
        for distribution in [BillingDistribution.appStore, .direct] {
            let flow = Self.flow(status: .connected, rpcUp: true)
            let store = makeSubscriptionStore(
                for: distribution,
                appStore: AppStoreSubscriptionManager(networkId: nil),
                stripe: StripeSubscriptionStore(client: StripeSubscriptionStoreTests.FakeClient(), openExternal: { _ in false }),
                connection: flow.model
            )
            #expect(store.distribution == distribution)

            await store.purchase(plan: .yearly, onSuccess: {})
            await flow.model.connectCommandsSettled()

            #expect(flow.events.all == ["notice", "disconnect", "connect"], "\(distribution)")
        }
    }

    /// Everything but the purchases reads through to the store behind it.
    @Test func theRestOfTheStoreReadsThrough() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        let store = flow.buying
        #expect(store.storeName == "fake")
        #expect(store.distribution == .direct)
        #expect(store.presentation(tier: nil, offer: nil, storefrontCountryName: nil) == nil)
        #expect(store.plansLoadFailed)
        store.retryLoadPlansIfNeeded(storefrontCountry: "US")
        #expect(flow.store.retriedCountry == "US")
        #expect(store.isPurchasing)
        #expect(store.purchaseSuccess)
        #expect(store.purchasePending)
        #expect(store.purchaseError == "error")
        #expect(store.purchaseConfirmingTitle == "title")
        #expect(store.purchaseConfirmingMessage == "message")
        #expect(store.checkoutView != nil)
        store.resetPurchaseState()
        #expect(flow.store.resetCount == 1)
        #expect(await store.restorePurchases() == .nothingToRestore)
        #expect(store.isRestoringPurchases)
        #expect(store.restoreResultMessage == "restored")
        // nothing there touched the connection
        await flow.model.connectCommandsSettled()
        #expect(flow.events.all.isEmpty)
    }

    /// Lets the work already on the main actor run: the purchase's task up to
    /// its first real wait.
    private static func drainMain() async {
        for _ in 0..<20 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }
}
