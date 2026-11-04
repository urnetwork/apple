import Foundation
import SwiftUI
import Testing
import URnetworkSdk
@testable import URnetwork

/// The Mac App Store purchase flow (ConnectViewModel.purchaseAroundConnection,
/// which every surface's purchase goes through by ConnectionAwareSubscriptionStore).
/// It drops the connection for the store, so it tells the user first, and only
/// a connection the user requested is dropped and brought back: the rpc link to
/// the extension is up with none requested too, while providing or with the
/// kill switch on, and bringing "it" back started a connection nobody asked for.
/// Every other build buys with the connection as it is
/// (BillingDistribution.purchaseDropsConnection). With the kill switch on the
/// store can't be reached around a disconnect, and the user is told to turn it
/// off instead.
///
/// The store, the sdk's commands and the notice are fakes, and the view model
/// the real one; `purchaseDropsConnection` stands in for the build, so this
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

    /// A Mac App Store flow with the sdk's controller reporting `status`, the
    /// device's rpc link `rpcUp` and its tunnel `tunnelStarted`, the kill switch
    /// `killSwitchOn`, and the user answering the notice `answer`. The balance
    /// is funded and fresh. Commands take effect at once unless `commands` holds
    /// them. The kill switch alert is an event too.
    private static func flow(
        status: ConnectionStatus?,
        rpcUp: Bool,
        tunnelStarted: Bool = false,
        killSwitchOn: Bool = false,
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
        model.killSwitchOn = { killSwitchOn }
        model.tellPurchaseNeedsKillSwitchOff = {
            events.append("kill switch")
        }
        let device = ConnectTapStateTests.FakeDevice(location: nil, tunnelStarted: tunnelStarted)
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

    // MARK: the kill switch

    /// The reported gap: with the kill switch on, the notice's disconnect did not
    /// free the store. The kill switch keeps the tunnel up after it
    /// (VPNDesiredState.shouldRun) and the sdk drops what it captures with no
    /// connection, so the purchase failed, and the notice had said the traffic
    /// would go around the VPN while it was blocked. The user is told to turn the
    /// kill switch off instead, and nothing is dropped, brought back or bought.
    @Test func aKillSwitchThatIsOnIsToldAndNothingIsDroppedOrBought() async {
        for status in [ConnectionStatus.connecting, .destinationSet, .connected, .connectFailed] {
            let flow = Self.flow(status: status, rpcUp: true, killSwitchOn: true)
            await flow.buy()
            await flow.buying.redeemOffer(Self.offer, onSuccess: {})
            await flow.model.connectCommandsSettled()
            #expect(flow.events.all == ["kill switch", "kill switch"], "\(status)")
        }
        let flow = Self.flow(status: .connected, rpcUp: true, killSwitchOn: true)
        await flow.buy()
        #expect(flow.model.connectionStatus == .connected)
    }

    /// With no connection requested the kill switch still runs the tunnel and
    /// drops what it captures, so the store can't be reached either.
    @Test func aKillSwitchThatIsOnWithTheTunnelUpAndNoConnectionIsTold() async {
        let flow = Self.flow(status: .disconnected, rpcUp: true, tunnelStarted: true, killSwitchOn: true)
        await flow.model.connectCommandsSettled()
        #expect(flow.model.tunnelConnected)
        await flow.buy()
        #expect(flow.events.all == ["kill switch"])
    }

    /// With no tunnel and no connection nothing stands in the store's way.
    @Test func aKillSwitchWithNoTunnelAndNoConnectionIsNotInTheWay() async {
        let flow = Self.flow(status: .disconnected, rpcUp: false, killSwitchOn: true)
        await flow.model.connectCommandsSettled()
        #expect(!flow.model.tunnelConnected)
        await flow.buy()
        #expect(flow.events.all == ["store yearly"])
    }

    /// The kill switch off: the notice, the disconnect, the store and the
    /// reconnect, as before.
    @Test func aKillSwitchThatIsOffKeepsTheNotice() async {
        let flow = Self.flow(status: .connected, rpcUp: true, tunnelStarted: true, killSwitchOn: false)
        await flow.model.connectCommandsSettled()
        await flow.buy()
        #expect(flow.events.all == ["notice", "disconnect", "store yearly", "connect"])
    }

    /// One at a time, as for the notice: a tap while the alert is up does nothing.
    @Test func aSecondTapWhileTheKillSwitchAlertIsUpDoesNothing() async {
        let flow = Self.flow(status: .connected, rpcUp: true, killSwitchOn: true)
        var tapped = false
        flow.model.tellPurchaseNeedsKillSwitchOff = { [buying = flow.buying, events = flow.events] in
            events.append("kill switch")
            guard !tapped else {
                return
            }
            tapped = true
            await buying.purchase(plan: .monthly, onSuccess: {})
        }
        await flow.buy()
        #expect(flow.events.all == ["kill switch"])
    }

    /// The direct download keeps the connection, so the kill switch is not asked
    /// about: connected, its page goes through the tunnel.
    @Test func theDirectDownloadIsNotStoppedForTheKillSwitch() async {
        let flow = Self.flow(status: .connected, rpcUp: true, tunnelStarted: true, killSwitchOn: true)
        flow.model.purchaseDropsConnection = BillingDistribution.direct.purchaseDropsConnection
        await flow.model.connectCommandsSettled()
        await flow.buy()
        #expect(flow.events.all == ["store yearly"])
    }

    /// Until the app hands it the setting (NetworkApp), the kill switch reads off,
    /// which is the flow as it was.
    @Test func theKillSwitchReadsOffUntilTheAppHandsItTheSetting() {
        #expect(!ConnectViewModel().killSwitchOn())
    }

    // MARK: the builds and the stores

    /// iOS and the direct download keep the connection, so nothing is dropped
    /// and there is nothing to tell: iOS App Store traffic does not ride the
    /// tunnel (the A6 note on AppStoreSubscriptionManager.purchase), and the
    /// direct download's page rides it whatever happens around the purchase call.
    @Test func withoutTheDropThereIsNoNoticeAndNoDisconnect() async {
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.model.purchaseDropsConnection = false
        await flow.buy()
        #expect(flow.events.all == ["store yearly"])
        #expect(flow.model.connectionStatus == .connected)
    }

    /// Only the Mac App Store build drops the connection for a purchase. The
    /// direct download's page loads after the purchase call has returned, so a
    /// drop around the call was over before the page asked for anything: it
    /// gained nothing, left the traffic unprotected for a moment, and the
    /// notice's Cancel stopped the purchase.
    @Test func onlyTheMacAppStoreBuildDropsTheConnection() {
        #expect(!BillingDistribution.direct.purchaseDropsConnection)
        #if os(macOS)
        #expect(BillingDistribution.appStore.purchaseDropsConnection)
        #else
        #expect(!BillingDistribution.appStore.purchaseDropsConnection)
        #endif
    }

    /// The view model drops the connection as its build does.
    @Test func theViewModelDropsAsItsBuildDoes() {
        #expect(ConnectViewModel().purchaseDropsConnection == BillingDistribution.current.purchaseDropsConnection)
        #if DIRECT_DOWNLOAD
        #expect(!ConnectViewModel().purchaseDropsConnection)
        #endif
    }

    /// The reported gap: the direct download disconnected for its checkout and
    /// reconnected before the page loaded. It buys with the connection as it is
    /// now, whatever the user requested: no notice, no disconnect, nothing
    /// brought back, and the welcome offer the same.
    @Test func theDirectDownloadBuysWithTheConnectionAsItIs() async {
        for status in [ConnectionStatus.connecting, .destinationSet, .connected, .connectFailed, .disconnected] {
            let flow = Self.flow(status: status, rpcUp: true)
            flow.model.purchaseDropsConnection = BillingDistribution.direct.purchaseDropsConnection
            await flow.buy()
            await flow.buying.redeemOffer(Self.offer, onSuccess: {})
            await flow.model.connectCommandsSettled()
            #expect(flow.events.all == ["store yearly", "store offer"], "\(status)")
        }
        let flow = Self.flow(status: .connected, rpcUp: true)
        flow.model.purchaseDropsConnection = BillingDistribution.direct.purchaseDropsConnection
        await flow.buy()
        #expect(flow.model.connectionStatus == .connected)
    }

    /// A surface gets its store from the factory, so neither store can be bought
    /// from past the flow. Neither sells here, the manager with no network and the
    /// client with no server: both refuse, after the flow's notice and disconnect
    /// where the flow drops the connection (the Mac App Store build, stood in for
    /// here), and with the connection as it is where it does not.
    @Test func bothStoresTheFactoryMakesGoThroughTheFlow() async {
        for distribution in [BillingDistribution.appStore, .direct] {
            for drops in [true, false] {
                let flow = Self.flow(status: .connected, rpcUp: true)
                flow.model.purchaseDropsConnection = drops
                let store = makeSubscriptionStore(
                    for: distribution,
                    appStore: AppStoreSubscriptionManager(networkId: nil),
                    stripe: StripeSubscriptionStore(client: StripeSubscriptionStoreTests.FakeClient(), openExternal: { _ in false }),
                    connection: flow.model
                )
                #expect(store.distribution == distribution)

                await store.purchase(plan: .yearly, onSuccess: {})
                await flow.model.connectCommandsSettled()

                let expected: [String] = drops ? ["notice", "disconnect", "connect"] : []
                #expect(flow.events.all == expected, "\(distribution) drops \(drops)")
            }
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
