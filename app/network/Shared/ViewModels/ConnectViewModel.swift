//
//  ConnectViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk
import SwiftUI
import Combine

private class GridListener: NSObject, SdkGridListenerProtocol {
    private let lock = NSLock()
    private var scheduled = false
    private var dirty = false
    private let callback: @MainActor () -> Void

    init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    func gridChanged() {
        lock.lock()
        if scheduled {
            dirty = true
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        callback()

        lock.lock()
        if dirty {
            dirty = false
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.drain()
            }
        } else {
            scheduled = false
            lock.unlock()
        }
    }
}

private class ConnectionStatusListener: NSObject, SdkConnectionStatusListenerProtocol {

    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    
    func connectionStatusChanged() {
        callback()
    }
    
}

private class SelectedLocationListener: NSObject, SdkSelectedLocationListenerProtocol {
    
    private let callback: (_ location: SdkConnectLocation?) -> Void

    init(callback: @escaping (SdkConnectLocation?) -> Void) {
        self.callback = callback
    }
    
    func selectedLocationChanged(_ location: SdkConnectLocation?) {
        callback(location)
    }
}

private class ConnectLocationStateListener: NSObject, SdkConnectLocationChangeListenerProtocol {
    private let callback: (_ location: SdkConnectLocation?) -> Void

    init(callback: @escaping (_ location: SdkConnectLocation?) -> Void) {
        self.callback = callback
    }

    func connectLocationChanged(_ location: SdkConnectLocation?) {
        callback(location)
    }
}

@MainActor
class ConnectViewModel: ObservableObject {
    
    /**
     * Connection status: what the connect views show. A tap shows its state
     * at once: a connect or disconnect the sdk has not finished, and a start
     * waiting on its balance, stand in for the sdk's status (see
     * runConnectCommand and admitConnect).
     */
    @Published private(set) var connectionStatus: ConnectionStatus?
    
    /**
     * Connect grid
     */
    @Published private(set) var windowCurrentSize: Int32 = 0
    @Published private(set) var gridPoints: [SdkId: SdkProviderGridPoint] = [:]
    @Published private(set) var gridWidth: Int32 = 0
    
    /**
     * Selected Provider
     */
    @Published private(set) var selectedProvider: SdkConnectLocation?
    
    /**
     * Prompt ratings
     */
    var requestReview: (() -> Void)?
    
    /**
     * Tunnel connected
     */
    @Published var tunnelConnected: Bool = false
    
    /**
     * Contract status
     */
    @Published private(set) var contractStatus: SdkContractStatus? = nil
    
    /**
     * Upgrade prompts
     */
    @Published var isPresentedUpgradeSheet: Bool = false {
        didSet {
            if !isPresentedUpgradeSheet {
                upgradeOpenedByStartConnectBlock = false
            }
        }
    }

    /// The upgrade sheet was opened by a start connect refused for the
    /// balance (admitConnect), not by Get Pro or a link: the sheet then says
    /// when the free data refreshes (upgradeShowsFreeRefresh). Cleared when the
    /// sheet closes.
    @Published private(set) var upgradeOpenedByStartConnectBlock = false
    
    private var api: SdkApi?
    var device: SdkDeviceRemote?
    var connectViewController: SdkConnectViewController?
    
    private var gridListenerSub: SdkSubProtocol?
    private var connectionStatusListenerSub: SdkSubProtocol?
    private var selectedLocationListenerSub: SdkSubProtocol?
    private var tunnelListenerSub: SdkSubProtocol?
    private var contractListenerSub: SdkSubProtocol?
    private var connectLocationStateSub: SdkSubProtocol?
    private var contractStatusGeneration = 0
    private var contractStatusRevision = 0
    private var contractStatusRefreshGenerations = Set<Int>()
    private var queuedContractStatusRefresh: (
        generation: Int, revision: Int, read: () -> SdkContractStatus?
    )?
    var contractStatusRefreshPending: Bool {
        !contractStatusRefreshGenerations.isEmpty || queuedContractStatusRefresh != nil
    }

    // insufficient balance: the gate inputs pushed by the connect views, and
    // the reaction that posts the held-traffic notice (never a disconnect)
    // nil until a connect view reports the plan
    private var insufficientBalancePlan: Plan? = nil
    private var insufficientBalancePolling: Bool = false
    // the start gate's inputs, replaced in tests: the App Group balance the
    // app, the tunnel and the gate itself save on every fetch, the clock, and
    // the bounded fetch used when that balance is stale
    var loadCachedBalance: () -> WidgetBalanceSnapshot? = { WidgetSnapshotStore.loadBalance() }
    var now: () -> Date = { Date() }
    lazy var fetchBalance: () async -> WidgetBalanceSnapshot? = { [weak self] in
        await StartConnectBalanceFetch.fetch(api: self?.api)
    }
    // a start waiting on its balance fetch; a repeated tap does not stack, and
    // a disconnect or sign out cancels it
    private(set) var startConnectTask: Task<Void, Never>?

    // connect and disconnect commands, run off the main actor in the order
    // they were made (see runConnectCommand)
    private let connectCommandQueue = DispatchQueue(label: "network.ur.connect-commands", qos: .userInitiated)
    // runs one command against the sdk, on the command queue; replaced in tests
    var performConnectCommand: (ConnectCommand, SdkConnectViewController?, SdkDeviceRemote?) -> Void = ConnectViewModel.performOnSdk
    // the presented controller's status; replaced in tests
    lazy var readConnectionStatus: () -> String? = { [weak self] in
        self?.connectViewController?.getConnectionStatus()
    }
    // commands queued and not finished, and the status the newest one shows
    private var pendingConnectCommandCount = 0
    private var pendingConnectCommandStatus: ConnectionStatus? = nil
    // the status the sdk last reported
    private var reportedConnectionStatus: ConnectionStatus? = nil
    private lazy var insufficientBalanceReaction = InsufficientBalanceContractReaction(
        disconnect: { [weak self] in self?.disconnect() },
        notice: { action in InsufficientBalanceNotice.apply(action) }
    )

    // a connect insufficient balance blocked, retried by itself once the
    // balance is back (BalanceRecovery): a start the gate refused, with the
    // location the user asked for (nil: the best available provider), or the
    // held connection
    private var balanceRecovery = BalanceRecovery<SdkConnectLocation?>()
    /// What the out-of-balance notice says about the recovery.
    @Published private(set) var balanceRecoveryState = BalanceRecoveryState()
    /// Bumps each time the recovery retried a blocked connect, so the connect
    /// views tell the user ("Data is available again. Reconnecting…").
    @Published private(set) var balanceRecoveryRetryCount = 0

    // last published grid signature; skip redundant re-renders when the SDK
    // re-emits a logically unchanged grid (its point objects get fresh
    // identities each notification, which would otherwise storm @Published)
    private var lastGridSignature: String = ""

    func setup(api: SdkApi?, device: SdkDeviceRemote, connectViewController: SdkConnectViewController?) {
        closeListeners()
        closeConnectViewController()

        self.api = api
        self.device = device
        self.connectViewController = connectViewController

        self.addGridListener()
        self.addConnectionStatusListener()
        self.addSelectedLocationListener()

        self.updateConnectionStatus()

        // if a user was connected and quit the app, it will reconnect this location
        self.selectedProvider = device.getConnectLocation()

        // if a user had selected a location, but wasn't connected, it will re-select that location
        if (self.selectedProvider == nil) {
            self.selectedProvider = device.getDefaultLocation()
        }

        /**
         * Add tunnel listener
         */
        self.tunnelListenerSub = self.device?.add(TunnelChangeListener { [weak self] tunnelStarted in
            guard let self = self else {
                return
            }

            DispatchQueue.main.async {
                if self.tunnelConnected != tunnelStarted {
                    self.tunnelConnected = tunnelStarted
                }
            }
        })

        self.refreshTunnelStatus()

        self.contractListenerSub = device.add(makeContractStatusListener())
        // the listener only reports changes: a balance that was already
        // insufficient must show the gate and its notice now
        self.updateContractStatus()
    }

    /**
     * Release all presentation-only SDK work while retaining the last device and
     * published snapshot. The packet tunnel/provider owns data-plane continuity;
     * reopening the scene calls `setup` and obtains a fresh controller snapshot.
     */
    func suspend(api: SdkApi?, device: SdkDeviceRemote?) {
        closeListeners()
        closeConnectViewController()
        self.api = api
        self.device = device
        addBackgroundConnectionStateListener()
    }

    func reset() {
        closeListeners()
        closeConnectViewController()

        self.api = nil
        self.device = nil

        // a start still waiting on its balance must not connect the next account
        self.cancelStartConnect()
        self.reportedConnectionStatus = nil
        self.publishConnectionStatus()
        self.windowCurrentSize = 0
        self.gridPoints = [:]
        self.gridWidth = 0
        self.lastGridSignature = ""
        self.selectedProvider = nil
        self.tunnelConnected = false
        self.contractStatus = nil
        self.isPresentedUpgradeSheet = false
        // a signed out account's episode is over: withdraw its notice
        self.insufficientBalanceReaction.reset()
        // and a connect it asked for must not start later
        self.clearBalanceRecovery()
    }

    private func closeListeners() {
        // A queued callback or refresh from a retired presentation/device
        // must not publish status or disconnect its replacement.
        contractStatusGeneration += 1
        queuedContractStatusRefresh = nil
        gridListenerSub?.close()
        connectionStatusListenerSub?.close()
        selectedLocationListenerSub?.close()
        tunnelListenerSub?.close()
        contractListenerSub?.close()
        connectLocationStateSub?.close()

        gridListenerSub = nil
        connectionStatusListenerSub = nil
        selectedLocationListenerSub = nil
        tunnelListenerSub = nil
        contractListenerSub = nil
        connectLocationStateSub = nil
    }

    private func closeConnectViewController() {
        if let connectViewController {
            if let device {
                device.close(connectViewController)
            } else {
                connectViewController.close()
            }
        }
        connectViewController = nil
    }

    /**
     * The macOS tray stays interactive while its window is hidden. Keep only
     * the device's event-driven location state so tray connect/disconnect
     * commands update their label; all polling and presentation controllers
     * remain closed. On iOS this listener is inert while the app is suspended.
     */
    private func addBackgroundConnectionStateListener() {
        guard let device else {
            return
        }

        updateBackgroundConnectionState(device.getConnectLocation())
        connectLocationStateSub = device.add(ConnectLocationStateListener { [weak self] location in
            DispatchQueue.main.async {
                self?.updateBackgroundConnectionState(location)
            }
        })
    }

    private func updateBackgroundConnectionState(_ location: SdkConnectLocation?) {
        // the device fires this on every location-state event; publish only
        // what changed so the tray/view is not re-rendered for a no-op
        if let location {
            selectedProvider = location
        }
        reportedConnectionStatus = location == nil ? .disconnected : .destinationSet
        publishConnectionStatus()
    }
    
    func refreshTunnelStatus() {
        let tunnelConnected = self.device?.getTunnelStarted() ?? false
        if self.tunnelConnected != tunnelConnected {
            self.tunnelConnected = tunnelConnected
        }
    }
    
    #if DIRECT_DOWNLOAD
    /// Runs before every connect: the direct-download build's system
    /// extension activation check (NetworkApp wires it).
    var beforeConnect: (() -> Void)?
    #endif

    private func runBeforeConnect() {
        #if DIRECT_DOWNLOAD
        beforeConnect?()
        #endif
    }

    /**
     * Every connect entry point in the app (the connect button and globe, the
     * provider list, the macOS menu bar) passes through here. A start is
     * decided on a fresh balance, fetched first when the cached one is stale;
     * refused, it opens the upgrade sheet and calls `onUpgrade`. A connection
     * that is already requested proceeds at once (see
     * InsufficientBalancePolicy). `proceed` runs at most once.
     *
     * The fetch can take up to `startConnectBalanceFetchTimeout`, so the tap
     * shows the connecting state while it runs (owner report 2026-10-16). A
     * refused start goes back to the status the sdk reports as the upgrade
     * sheet opens; an admitted one runs its command, which keeps the same
     * state, so the view never steps back to disconnected in between. Only
     * the display changes: the decision is the same, and a start waiting on
     * its balance is not a requested connection to the gate or the recovery
     * (`requestedConnectionStatus`).
     */
    private func admitConnect(
        _ attempt: ConnectAttempt,
        target: SdkConnectLocation?,
        onUpgrade: (() -> Void)? = nil,
        proceed: @escaping () -> Void
    ) {
        let apply = { [weak self] (decision: ConnectAttemptDecision) in
            switch decision {
            case .connect:
                // this connect replaces one still waiting on the balance
                self?.clearBalanceRecovery()
                proceed()
            case .upgrade:
                // nothing connects: back to what the sdk reports
                self?.publishConnectionStatus()
                // the refused start waits on the balance and is retried by
                // itself once it is back (BalanceRecovery)
                if let self {
                    self.balanceRecovery.startRefused(target, now: self.now())
                    self.publishBalanceRecoveryState()
                }
                self?.upgradeOpenedByStartConnectBlock = true
                self?.isPresentedUpgradeSheet = true
                onUpgrade?()
            }
        }
        let guards = startConnectGuards
        if let decision = immediateStartConnectDecision(
            attempt, guards: guards, cachedBalance: loadCachedBalance(), now: now()
        ) {
            apply(decision)
            return
        }
        if startConnectTask != nil {
            return
        }
        let fetchBalance = self.fetchBalance
        startConnectTask = Task { @MainActor [weak self] in
            let balance = await fetchBalance()
            // a disconnect or sign out while the balance was fetched cancelled
            // this start, and a newer start may own the task slot by now
            guard let self, !Task.isCancelled else {
                return
            }
            self.startConnectTask = nil
            apply(startConnectDecision(attempt, guards: guards, balance: balance))
            self.publishConnectionStatus()
        }
        publishConnectionStatus()
    }

    /// A start still waiting on its balance never connects.
    private func cancelStartConnect() {
        startConnectTask?.cancel()
        startConnectTask = nil
    }

    private var startConnectGuards: StartConnectGuards {
        StartConnectGuards(
            contractInsufficientBalance: contractStatus?.insufficientBalance == true,
            // before a connect view reports the plan (the macOS menu bar with
            // the window never shown) the balance's Pro flag stands in
            isSupporter: insufficientBalancePlan == .supporter,
            isPollingSubscriptionBalance: insufficientBalancePolling
        )
    }

    private var currentConnectAttempt: ConnectAttempt {
        connectAttempt(connectionStatus: requestedConnectionStatus)
    }

    /**
     * Used in the provider list
     */
    func connect(_ provider: SdkConnectLocation) {
        admitConnect(currentConnectAttempt, target: provider) { [weak self] in
            guard let self else {
                return
            }
            self.runBeforeConnect()
            let device = self.device
            self.runConnectCommand(.connect(provider)) {
                try? device?.getNetworkSpace()?.getAsyncLocalState()?.getLocalState()?.setConnectLocation(provider)
            }
        }
    }

    /**
     * Used for the main  connect button
     */
    func connect() {
        admitConnect(currentConnectAttempt, target: selectedProvider) { [weak self] in
            self?.connectSelected()
        }
    }

    /**
     * The main connect from outside the connect view: `onUpgrade` runs when a
     * start is refused out of balance (the macOS menu bar opens the window
     * for the sheet).
     */
    func connect(onUpgrade: @escaping () -> Void) {
        admitConnect(currentConnectAttempt, target: selectedProvider, onUpgrade: onUpgrade) { [weak self] in
            self?.connectSelected()
        }
    }

    /**
     * Reconnects a connection the app itself dropped (the macOS purchase flow
     * disconnects around the store): the user never left it, so it is not a
     * start.
     */
    func restoreConnect() {
        admitConnect(.alreadyConnected, target: selectedProvider) { [weak self] in
            self?.connectSelected()
        }
    }

    private func connectSelected() {
        runBeforeConnect()
        if let selectedProvider = self.selectedProvider {
            runConnectCommand(.connect(selectedProvider))
        } else {
            startBestAvailable()
        }
    }

    func connectBestAvailable() {
        admitConnect(currentConnectAttempt, target: nil) { [weak self] in
            self?.startBestAvailable()
        }
    }

    private func startBestAvailable() {
        runBeforeConnect()
        runConnectCommand(.connectBestAvailable)
    }

    func disconnect() {
        // the user's disconnect: nothing is reconnected by itself after it,
        // and a start still waiting on its balance does not connect
        clearBalanceRecovery()
        cancelStartConnect()
        runConnectCommand(.disconnect)
    }

    /**
     * Shows `command`'s state at once and runs it on the command queue
     * (`performConnectCommand`, which also records the app's intent), then
     * `then`.
     *
     * With the tunnel up, the sdk's Connect and Disconnect make several
     * blocking round trips to the extension (the provide mode under Auto, the
     * location, the default), and the sdk's status reaches the main actor
     * only after them. Run on the main actor, a tap showed nothing until the
     * extension answered (owner report 2026-10-16). Commands run in the order
     * they were made. Until the last one returns, the status it starts with
     * (the sdk's own first status for the gesture) stands in for the sdk's,
     * so a report from before it cannot flip the view back, and the sdk's
     * status is read again once it has returned.
     */
    private func runConnectCommand(_ command: ConnectCommand, then: (() -> Void)? = nil) {
        let perform = performConnectCommand
        let viewController = connectViewController
        let device = self.device
        pendingConnectCommandCount += 1
        pendingConnectCommandStatus = command.startStatus
        publishConnectionStatus()
        connectCommandQueue.async {
            perform(command, viewController, device)
            then?()
            DispatchQueue.main.async { [weak self] in
                self?.connectCommandFinished()
            }
        }
    }

    private func connectCommandFinished() {
        pendingConnectCommandCount -= 1
        if 0 < pendingConnectCommandCount {
            return
        }
        pendingConnectCommandStatus = nil
        // the sdk has every command now
        updateConnectionStatus()
        publishConnectionStatus()
    }

    /// Returns once every command made so far has run and its status was
    /// applied. Sign out and the macOS purchase flow wait on it, as they did
    /// on the disconnect itself when it ran on the main actor, and so does
    /// every macOS quit, for at most its cap (QuitSequence).
    func connectCommandsSettled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connectCommandQueue.async {
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    /// What the user asked for so far: the newest command not yet finished,
    /// else what the sdk reports. A start waiting on its balance is not in
    /// it: nothing is asked of the sdk until the gate admits it.
    private var requestedConnectionStatus: ConnectionStatus? {
        0 < pendingConnectCommandCount ? pendingConnectCommandStatus : reportedConnectionStatus
    }

    /// Publishes what the connect views show: connecting while a start waits
    /// on its balance, else the requested status. Only on a change.
    private func publishConnectionStatus() {
        let status: ConnectionStatus? = startConnectTask != nil ? .destinationSet : requestedConnectionStatus
        if status == connectionStatus {
            return
        }
        connectionStatus = status
        if status == .connected {
            requestReview?()
        }
    }
    
    private func addSelectedLocationListener() {
        let listener = SelectedLocationListener { [weak self] selectedLocation in
            
            guard let self = self else {
                print("SelectedLocationListener no self found")
                return
            }
        
            DispatchQueue.main.async {
                print("new selected location is: \(selectedLocation?.name ?? "none")")
                self.selectedProvider = selectedLocation
            }
        }
        selectedLocationListenerSub = connectViewController?.add(listener)
    }
    
//    func getProviderColor(_ provider: SdkConnectLocation) -> Color {
//        return Color(hex: SdkGetColorHex(
//            provider.locationType == SdkLocationTypeCountry ? provider.countryCode : provider.connectLocationId?.string()
//        ))
//    }
    
}

// MARK: Contract status
extension ConnectViewModel {
    func updateContractStatus() {
        guard let device else { return }
        refreshContractStatus { device.getContractStatus() }
    }

    // SDK getters can synchronously call the VPN extension. Coalesce each
    // generation off-main, allowing a replacement to proceed beside one old
    // read. At most two reads run; further replacements retain only the newest
    // queued request. Notifications never need to wait behind these reads.
    func refreshContractStatus(using read: @escaping () -> SdkContractStatus?) {
        guard !contractStatusRefreshGenerations.contains(contractStatusGeneration) else { return }
        let request = (generation: contractStatusGeneration, revision: contractStatusRevision, read: read)
        guard contractStatusRefreshGenerations.count < 2 else {
            queuedContractStatusRefresh = request
            return
        }
        startContractStatusRefresh(request)
    }

    private func startContractStatusRefresh(
        _ request: (generation: Int, revision: Int, read: () -> SdkContractStatus?)
    ) {
        contractStatusRefreshGenerations.insert(request.generation)
        let read = request.read
        let generation = request.generation
        let revision = request.revision
        DispatchQueue.global(qos: .userInitiated).async {
            let status = read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.contractStatusRefreshGenerations.remove(generation)
                if self.contractStatusGeneration == generation,
                   self.contractStatusRevision == revision {
                    self.applyContractStatus(status)
                }
                if let queued = self.queuedContractStatusRefresh {
                    self.queuedContractStatusRefresh = nil
                    if self.contractStatusGeneration == queued.generation,
                       self.contractStatusRevision == queued.revision {
                        self.startContractStatusRefresh(queued)
                    }
                }
            }
        }
    }

    func makeContractStatusListener() -> ContractStatusChangeListener {
        let generation = contractStatusGeneration
        return ContractStatusChangeListener { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.contractStatusGeneration == generation else { return }
                // The notification already carries the SDK's current value.
                // Calling its synchronous getter here adds another RPC.
                self.applyContractStatus(status)
            }
        }
    }

    private func applyContractStatus(_ status: SdkContractStatus?) {
        contractStatusRevision += 1
        // only publish when a field the UI reads actually changed; the SDK
        // re-emits a fresh SdkContractStatus (new identity) each callback, which
        // would otherwise re-render the whole connect screen on every tick
        if !Self.contractStatusEqual(status, self.contractStatus) {
            self.contractStatus = status
        }

        evaluateInsufficientBalance()
    }

    /// Plan and polling live with the subscription views; the connect views
    /// push them here so the notice uses the same gate they render.
    func updateInsufficientBalanceGuards(plan: Plan, isPollingSubscriptionBalance: Bool) {
        if insufficientBalancePlan == plan && insufficientBalancePolling == isPollingSubscriptionBalance {
            return
        }
        insufficientBalancePlan = plan
        insufficientBalancePolling = isPollingSubscriptionBalance
        evaluateInsufficientBalance()
    }

    /// Out of balance keeps the connect request: the tunnel holds traffic
    /// until the user upgrades or disconnects (see InsufficientBalancePolicy).
    private func evaluateInsufficientBalance() {
        insufficientBalanceReaction.update(
            insufficientBalance: contractStatus?.insufficientBalance == true,
            isSupporter: insufficientBalancePlan == .supporter,
            // an unknown plan defers the notice like a poll, so a supporter
            // is never told before the plan arrives
            isPolling: insufficientBalancePolling || insufficientBalancePlan == nil,
            connectionStatus: requestedConnectionStatus
        )
        evaluateBalanceRecovery()
    }

    private static func contractStatusEqual(_ a: SdkContractStatus?, _ b: SdkContractStatus?) -> Bool {
        if a == nil, b == nil { return true }
        guard let a = a, let b = b else { return false }
        return a.insufficientBalance == b.insufficientBalance
            && a.noPermission == b.noPermission
            && a.premium == b.premium
    }
}

// MARK: balance recovery
extension ConnectViewModel {
    /// A new account balance reading: the subscription views fetch it and
    /// save it to the App Group, where `loadCachedBalance` reads it.
    func balanceReadingChanged() {
        evaluateBalanceRecovery()
    }

    /// The user cancelled the wait (Cancel), connected, disconnected or signed
    /// out: nothing they asked for is waiting on the balance any more.
    func clearBalanceRecovery() {
        balanceRecovery.clear()
        publishBalanceRecoveryState()
    }

    /// Feeds the recovery the gate this view model renders, whether a
    /// connection is requested and the last account balance, and makes the
    /// retry it decides on. The gate is not asked again for the retry: the
    /// recovery decided on a fresh balance, and a held connection still
    /// reports insufficient balance until the rebuild replaces it.
    private func evaluateBalanceRecovery() {
        let step = balanceRecovery.observe(
            gate: insufficientBalanceGateActive(
                insufficientBalance: contractStatus?.insufficientBalance == true,
                plan: insufficientBalancePlan ?? Plan.none,
                isPollingSubscriptionBalance: insufficientBalancePolling
            ),
            connectRequested: connectAttempt(connectionStatus: requestedConnectionStatus) == .alreadyConnected,
            balance: loadCachedBalance(),
            now: now()
        )
        publishBalanceRecoveryState()
        let command: ConnectCommand
        switch step {
        case .noRetry:
            return
        case .start(let location):
            command = location.map { .connect($0) } ?? .connectBestAvailable
        case .rebuild:
            // the device's location is read with the command, off the main actor
            command = .rebuild(fallback: selectedProvider)
        }
        print("[connect]balance is back: retrying the blocked connect")
        runBeforeConnect()
        runConnectCommand(command)
        balanceRecoveryRetryCount += 1
    }

    /// Publishes the recovery's state, only when it changed.
    private func publishBalanceRecoveryState() {
        let state = balanceRecovery.state
        if balanceRecoveryState != state {
            balanceRecoveryState = state
        }
    }
}

// MARK: grid
extension ConnectViewModel {
    
    private func addGridListener() {
        let listener = GridListener { [weak self] in
            self?.updateGrid()
        }
        gridListenerSub = connectViewController?.add(listener)
        updateGrid()
    }
    
    private func gridSignature() -> String {
        guard let grid = self.connectViewController?.getGrid() else { return "" }
        var points: [ConnectGridPointSignature] = []
        if let list = grid.getProviderGridPointList() {
            for i in 0..<list.len() {
                if let p = list.get(i), let cid = p.clientId {
                    points.append(ConnectGridPointSignature(id: cid.idStr, point: p))
                }
            }
        }
        return connectGridSignature(
            width: grid.getWidth(),
            windowCurrentSize: grid.getWindowCurrentSize(),
            points: points
        )
    }

    func updateGrid() {

        // skip the @Published publish (and the downstream re-render + grid
        // animation) when the grid is logically unchanged. the SDK re-emits
        // grid notifications with fresh point objects, so assigning gridPoints
        // unconditionally would storm observers on every notification even when
        // nothing actually moved — a real cost during connect/reconnect churn.
        let signature = gridSignature()
        if signature == lastGridSignature {
            return
        }
        lastGridSignature = signature

       if let grid = self.connectViewController?.getGrid() {
           self.gridWidth = grid.getWidth()
           self.windowCurrentSize = grid.getWindowCurrentSize()
           
           let gridPointList = grid.getProviderGridPointList()
           
           guard let gridPointList = gridPointList else {
               return
           }
           
           var gridPoints: [SdkId: SdkProviderGridPoint] = [:]
           
           for i in 0..<gridPointList.len() {
               
               let gridPoint = gridPointList.get(i)
               
               if let gridPoint = gridPoint, let clientId = gridPoint.clientId {
                   gridPoints[clientId] = gridPoint
               }
               
           }
           
           self.gridPoints = gridPoints
           
       } else {
           self.windowCurrentSize = 0
           self.gridPoints = [:]
           self.gridWidth = 0
       }
        
    }
    
}

// MARK: - the grid signature
//
// Free functions and a plain value rather than view-model state, so what the
// signature covers is exercised directly by the unit tests.

/**
 * One provider's contribution to the grid signature: everything the grid
 * draws from that point.
 *
 * A field the ui renders but the signature omits is a change the canvas and
 * the drawer would never see, because `updateGrid` skips the publish when the
 * signature is unchanged. The ip family is the histogram's row (IPV6.md D2)
 * and the extender ips are the dots' rings (EXTENDER.md K2); both change on
 * their own, without a state, position or membership change.
 */
struct ConnectGridPointSignature: Equatable {
    let id: String
    let state: String
    let x: Int32
    let y: Int32
    let ipFamily: String
    let extenderIps: String

    init(id: String, state: String, x: Int32, y: Int32, ipFamily: String, extenderIps: String) {
        self.id = id
        self.state = state
        self.x = x
        self.y = y
        self.ipFamily = ipFamily
        self.extenderIps = extenderIps
    }

    init(id: String, point: SdkProviderGridPoint) {
        self.init(
            id: id,
            state: point.state,
            x: point.x,
            y: point.y,
            ipFamily: point.ipFamily,
            extenderIps: point.extenderIps
        )
    }

    var text: String {
        "\(id):\(state):\(x):\(y):\(ipFamily):\(extenderIps)"
    }
}

/// The whole grid as one comparable string. Points are sorted, so the sdk's
/// list order is not itself a change.
func connectGridSignature(
    width: Int32,
    windowCurrentSize: Int32,
    points: [ConnectGridPointSignature]
) -> String {
    "\(width)x\(windowCurrentSize);" + points.map { $0.text }.sorted().joined(separator: "|")
}

// MARK: connection status
extension ConnectViewModel {
    
    private func addConnectionStatusListener() {
        let listener = ConnectionStatusListener { [weak self] in
            guard let self = self else {
                return
            }
                
            DispatchQueue.main.async {
                self.updateConnectionStatus()
            }
            
        }
        connectionStatusListenerSub = connectViewController?.add(listener)
    }

    /// Reads the sdk's status (the listener's hop to the main actor). The
    /// view shows it unless a tap is still pending (publishConnectionStatus).
    func updateConnectionStatus() {
        guard let statusString = readConnectionStatus() else {
            print("no status present")
            return
        }
        guard let status = ConnectionStatus(rawValue: statusString),
              status != reportedConnectionStatus else {
            return
        }
        reportedConnectionStatus = status
        publishConnectionStatus()
        evaluateBalanceRecovery()
    }
    
}

// MARK: connect commands

/// One connect or disconnect the view model asks the sdk for.
enum ConnectCommand: Equatable {
    case connect(SdkConnectLocation)
    case connectBestAvailable
    /// The held connection again: to the device's location, else `fallback`,
    /// else the best available provider (the balance recovery's rebuild).
    case rebuild(fallback: SdkConnectLocation?)
    case disconnect

    /// The sdk controller's own first status for the command, which the
    /// connect views show from the tap until it has run.
    var startStatus: ConnectionStatus {
        self == .disconnect ? .disconnected : .destinationSet
    }
}

extension ConnectViewModel {
    /// Runs `command` on the presented controller or, without one (the macOS
    /// menu bar while the window is hidden), on a controller opened for it,
    /// then records the in-app decision: the quick connect surfaces and the
    /// tunnel extension see it through the shared intent. Blocks while the
    /// sdk talks to the tunnel extension: it runs on the command queue, never
    /// on the main actor.
    nonisolated static func performOnSdk(
        _ command: ConnectCommand,
        viewController: SdkConnectViewController?,
        device: SdkDeviceRemote?
    ) {
        defer {
            TunnelIntentAdoption.recordAppIntent(connect: command != .disconnect, device: device)
        }
        let run = { (viewController: SdkConnectViewController) in
            switch command {
            case .connect(let location):
                viewController.connect(location)
            case .connectBestAvailable:
                viewController.connectBestAvailable()
            case .rebuild(let fallback):
                if let location = device?.getConnectLocation() ?? fallback {
                    viewController.connect(location)
                } else {
                    viewController.connectBestAvailable()
                }
            case .disconnect:
                viewController.disconnect()
            }
        }
        if let viewController {
            run(viewController)
            return
        }
        guard let device, let viewController = device.openConnectViewController() else {
            return
        }
        defer {
            device.close(viewController)
        }
        run(viewController)
    }
}

// MARK: start connect balance

/// The bounded subscription balance fetch a start connect makes when the
/// cached balance is stale (see InsufficientBalancePolicy). A result is saved
/// to the App Group stamped now, so the other surfaces read it as fresh. No
/// api, an error or the timeout give nil, which never blocks a start.
enum StartConnectBalanceFetch {
    static func fetch(api: SdkApi?, timeout: TimeInterval = startConnectBalanceFetchTimeout) async -> WidgetBalanceSnapshot? {
        guard let api else {
            return nil
        }
        let resume = StartConnectBalanceResume()
        let balance = await withCheckedContinuation { (continuation: CheckedContinuation<WidgetBalanceSnapshot?, Never>) in
            resume.set(continuation)
            // the callback is held by the closure until it reports
            let callback = StartConnectBalanceCallback { result in
                resume.resume(result.map { result in
                    WidgetBalanceSnapshot(
                        updatedAt: Date(),
                        startBalanceByteCount: result.startBalanceByteCount,
                        balanceByteCount: result.balanceByteCount,
                        openTransferByteCount: result.openTransferByteCount,
                        isPro: result.currentSubscription != nil
                    )
                })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume.resume(nil)
            }
            api.subscriptionBalance(callback)
        }
        if let balance {
            WidgetSnapshotStore.save(balance)
        }
        return balance
    }
}

/// Resumes the fetch's continuation exactly once, from the callback or the
/// timeout, whichever comes first. Safe for concurrent use.
private final class StartConnectBalanceResume: @unchecked Sendable {
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<WidgetBalanceSnapshot?, Never>?

    func set(_ continuation: CheckedContinuation<WidgetBalanceSnapshot?, Never>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.continuation = continuation
    }

    func resume(_ balance: WidgetBalanceSnapshot?) {
        let continuation: CheckedContinuation<WidgetBalanceSnapshot?, Never>? = {
            stateLock.lock()
            defer { stateLock.unlock() }
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }()
        continuation?.resume(returning: balance)
    }
}

private final class StartConnectBalanceCallback: NSObject, SdkSubscriptionBalanceCallbackProtocol {
    private let callback: (SdkSubscriptionBalanceResult?) -> Void

    init(_ callback: @escaping (SdkSubscriptionBalanceResult?) -> Void) {
        self.callback = callback
    }

    func result(_ result: SdkSubscriptionBalanceResult?, err: Error?) {
        callback(err == nil ? result : nil)
    }
}
