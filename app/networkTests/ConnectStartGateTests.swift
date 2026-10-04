import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// Every in-app connect entry point (the connect button and globe, the
/// provider list, the macOS menu bar) goes through ConnectViewModel. Out of
/// balance a start must not reach the tunnel: no connect is recorded and the
/// upgrade sheet opens instead (urnetwork/android#483). The balance is
/// decided fresh: a cached one older than a minute is fetched again first, and
/// a failed fetch never blocks. A connection the user never left is never
/// refused or dropped. No device is attached, so a connect that proceeds only
/// records the app's intent; the clock and the fetch are injected.
@MainActor
@Suite(.serialized)
struct ConnectStartGateTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let gib: Int64 = 1024 * 1024 * 1024

    private static func balance(_ balanceByteCount: Int64, isPro: Bool = false, age: TimeInterval = 0) -> WidgetBalanceSnapshot {
        WidgetBalanceSnapshot(
            updatedAt: now.addingTimeInterval(-age),
            startBalanceByteCount: gib,
            balanceByteCount: balanceByteCount,
            openTransferByteCount: 0,
            isPro: isPro
        )
    }

    /// Runs `body`, waits for a start that is fetching its balance, and
    /// reports whether a connect or disconnect intent was recorded (the
    /// in-app command reached the tunnel path), restoring the shared intent
    /// and the applied mark it may have written.
    private static func recordsIntent(_ model: ConnectViewModel, _ body: () async -> Void) async -> Bool {
        let shared = TunnelIntentStore.defaults
        let savedIntent = shared?.object(forKey: TunnelIntentStore.key)
        let savedAppliedAt = UserDefaults.standard.object(forKey: TunnelIntentAdoption.appliedAtKey)
        defer {
            shared?.set(savedIntent, forKey: TunnelIntentStore.key)
            UserDefaults.standard.set(savedAppliedAt, forKey: TunnelIntentAdoption.appliedAtKey)
        }
        let marker = Date(timeIntervalSince1970: 1)
        UserDefaults.standard.set(marker, forKey: TunnelIntentAdoption.appliedAtKey)
        await body()
        await model.startConnectTask?.value
        return TunnelIntentAdoption.appliedAt != marker
    }

    /// A fresh app start (no connect view has reported, no contract status)
    /// with the given cached balance and fetch result. `fetches` counts the
    /// fetches.
    private static func model(
        plan: Plan? = .none,
        cached: WidgetBalanceSnapshot?,
        fetched: WidgetBalanceSnapshot? = nil,
        fetches: Counter = Counter()
    ) -> ConnectViewModel {
        let model = ConnectViewModel()
        model.now = { now }
        model.loadCachedBalance = { cached }
        model.fetchBalance = {
            fetches.count += 1
            return fetched
        }
        if let plan {
            model.updateInsufficientBalanceGuards(plan: plan, isPollingSubscriptionBalance: false)
        }
        return model
    }

    final class Counter {
        var count = 0
    }

    // MARK: start connect

    /// The first connect after a fresh start on an account that is already
    /// empty used to start the tunnel: no contract status exists before the
    /// first connection, and the gate read nothing else.
    @Test func freshStartOnAnEmptyAccountOpensUpgradeAndDoesNotConnect() async {
        let model = Self.model(cached: Self.balance(0, age: 5))
        #expect(!(await Self.recordsIntent(model) { model.connect() }))
        #expect(model.isPresentedUpgradeSheet)
    }

    @Test func providerListOnAnEmptyAccountOpensUpgradeAndDoesNotConnect() async {
        let model = Self.model(cached: Self.balance(0))
        #expect(!(await Self.recordsIntent(model) { model.connect(SdkConnectLocation()) }))
        #expect(model.isPresentedUpgradeSheet)
        let bestAvailable = Self.model(cached: Self.balance(0))
        #expect(!(await Self.recordsIntent(bestAvailable) { bestAvailable.connectBestAvailable() }))
        #expect(bestAvailable.isPresentedUpgradeSheet)
    }

    /// The macOS menu bar connects before any connect view reported a plan,
    /// and opens the window for the sheet when refused.
    @Test func menuBarBeforeTheConnectViewIsRefusedAndOpensTheWindow() async {
        let model = Self.model(plan: nil, cached: Self.balance(0))
        var upgraded = false
        #expect(!(await Self.recordsIntent(model) { model.connect(onUpgrade: { upgraded = true }) }))
        #expect(upgraded)
        #expect(model.isPresentedUpgradeSheet)

        let pro = Self.model(plan: nil, cached: Self.balance(0, isPro: true))
        #expect(await Self.recordsIntent(pro) { pro.connect() })
        #expect(!pro.isPresentedUpgradeSheet)
    }

    /// Held out of balance, the user disconnects: the SDK resets the contract
    /// status with the connection, so the live status no longer says
    /// insufficient. The server's balance still does, fetched now because the
    /// cached one is old, and the next connect is a refused start.
    @Test func heldThenDisconnectedThenConnectIsRefused() async {
        let fetches = Counter()
        let model = Self.model(cached: Self.balance(Self.gib, age: 30 * 60), fetched: Self.balance(0), fetches: fetches)
        let insufficient = SdkContractStatus()
        insufficient.insufficientBalance = true
        let listener = model.makeContractStatusListener()
        listener.contractStatusChanged(insufficient)
        await Self.drainMain()
        #expect(model.contractStatus?.insufficientBalance == true)

        // the disconnect's destination change resets the status to empty
        #expect(await Self.recordsIntent(model) { model.disconnect() })
        listener.contractStatusChanged(SdkContractStatus())
        await Self.drainMain()
        #expect(model.contractStatus?.insufficientBalance == false)

        #expect(!(await Self.recordsIntent(model) { model.connect() }))
        #expect(model.isPresentedUpgradeSheet)
        #expect(fetches.count == 1)
    }

    /// A balance of zero from half an hour ago must not send an account that
    /// was topped up since to upgrade: it is fetched again first.
    @Test func staleEmptyBalanceOfAFundedAccountConnects() async {
        let fetches = Counter()
        let model = Self.model(cached: Self.balance(0, age: 30 * 60), fetched: Self.balance(Self.gib), fetches: fetches)
        #expect(await Self.recordsIntent(model) { model.connect() })
        #expect(!model.isPresentedUpgradeSheet)
        #expect(fetches.count == 1)
    }

    @Test func failedFetchDoesNotBlockTheConnect() async {
        let model = Self.model(cached: Self.balance(0, age: 61), fetched: nil)
        #expect(await Self.recordsIntent(model) { model.connect() })
        #expect(!model.isPresentedUpgradeSheet)
        let never = Self.model(cached: nil, fetched: nil)
        #expect(await Self.recordsIntent(never) { never.connect() })
        #expect(!never.isPresentedUpgradeSheet)
    }

    @Test func connectWithBalanceOrWhilePollingProceeds() async {
        let fetches = Counter()
        let funded = Self.model(cached: Self.balance(1), fetches: fetches)
        #expect(await Self.recordsIntent(funded) { funded.connect() })
        #expect(!funded.isPresentedUpgradeSheet)

        let polling = Self.model(plan: nil, cached: Self.balance(0), fetches: fetches)
        polling.updateInsufficientBalanceGuards(plan: .none, isPollingSubscriptionBalance: true)
        #expect(await Self.recordsIntent(polling) { polling.connect() })
        #expect(!polling.isPresentedUpgradeSheet)
        #expect(fetches.count == 0)
    }

    // MARK: already connected

    /// The reconnect after the macOS purchase flow restores a connection the
    /// user never left, so running out of balance does not keep it down.
    @Test func restoringAConnectionIsNotRefusedOutOfBalance() async {
        let fetches = Counter()
        let model = Self.model(cached: Self.balance(0), fetches: fetches)
        let insufficient = SdkContractStatus()
        insufficient.insufficientBalance = true
        model.makeContractStatusListener().contractStatusChanged(insufficient)
        await Self.drainMain()
        #expect(await Self.recordsIntent(model) { model.restoreConnect() })
        #expect(!model.isPresentedUpgradeSheet)
        #expect(fetches.count == 0)
    }

    /// Running out of balance on a live connection records no disconnect:
    /// the connection stays requested and traffic is held.
    @Test func runningOutOfBalanceNeverDropsTheConnection() async {
        let model = Self.model(cached: Self.balance(0))
        let insufficient = SdkContractStatus()
        insufficient.insufficientBalance = true
        let listener = model.makeContractStatusListener()
        #expect(!(await Self.recordsIntent(model) {
            listener.contractStatusChanged(insufficient)
            await Self.drainMain()
        }))
        #expect(model.contractStatus?.insufficientBalance == true)
        #expect(!(await Self.recordsIntent(model) {
            model.updateInsufficientBalanceGuards(plan: .none, isPollingSubscriptionBalance: true)
            model.updateInsufficientBalanceGuards(plan: .none, isPollingSubscriptionBalance: false)
        }))
    }

    /// Disconnect is never gated.
    @Test func disconnectOutOfBalanceIsNeverRefused() async {
        let model = Self.model(cached: Self.balance(0))
        #expect(await Self.recordsIntent(model) { model.disconnect() })
        #expect(!model.isPresentedUpgradeSheet)
    }

    /// Lets the listener's main queue hop run.
    private static func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
