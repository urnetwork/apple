//
//  WidgetSnapshotWriter.swift
//  network (packet tunnel extension)
//
//  Publishes what the Home Screen widgets show (see
//  network/Shared/Widgets/WidgetSnapshots.swift) from the process that owns
//  the truth: the connected location, the connected providers with their
//  coordinates and country colors, the per-minute throughput folded from the
//  device's cumulative byte and packet counters, and, on a slow cadence, the transfer
//  balance. Everything is written into the App Group container and WidgetKit
//  is asked to re-render, within a budget.
//
//  All work happens on one serial queue; SDK listener callbacks hop onto it.
//

import Foundation
import URnetworkExtensionSdk
import os

final class WidgetSnapshotWriter {

    /// How often the snapshot file is rewritten while the tunnel is up. Cheap
    /// (a few KB, atomic), so the next reload always finds fresh buckets.
    ///
    /// Half the chart's window: the newest bucket a reload can find is one
    /// write old, and a whole window of lag would leave the widget drawing
    /// the minute BEFORE the last one. Writes are not the budgeted resource
    /// -- WidgetKit reloads are -- so this is paid in a few KB, not in
    /// refreshes.
    static let writeInterval: TimeInterval = 30
    /// The write cadence while the app's Account > Widgets previews are on
    /// screen (WidgetPreviewVisibility): the previews read every write, so
    /// they move like the real widgets would if WidgetKit re-rendered that
    /// often. Back to `writeInterval` when the mark clears or expires.
    static let previewWriteInterval: TimeInterval = 2
    /// The floor between reloads of any ONE widget kind, whatever asked for
    /// it. Deliberately slower than the timeline's own policy
    /// (`WidgetRefreshPolicy`): this is a backstop filling a gap the policy
    /// left, not a second clock racing it -- every reload re-arms the
    /// timeline's `.after(...)`, so a faster second requester buys nothing and
    /// spends the same budget.
    ///
    /// These used to be per-REASON rather than per-kind, which let one kind be
    /// asked for far more often than the budget allows: providers joining and
    /// leaving drove the globe every 2 minutes (720 a day) and contract
    /// churn drove the contracts widget every 3 (480 a day), against the
    /// roughly 40-70 a day the comments alongside them cited.
    static let reloadBackstopInterval: TimeInterval = WidgetRefreshPolicy.extensionBackstopInterval
    /// A refresh request from a widget publishes at most this often, so a
    /// user tapping repeatedly cannot drive the write path. Under the intent's
    /// own wait, so a second tap is served rather than timing out.
    static let refreshRequestFloor: TimeInterval = 1
    /// Contract change events arrive per contract, about once a second while
    /// bytes move; the two lists are re-read at most this often.
    static let contractRefreshInterval: TimeInterval = 2
    /// How many peers / contracts per stack the snapshot keeps.
    static let contractPeerLimit = 12
    static let contractStackLimit = 6
    /// The balance is an API call; refresh it rarely.
    static let balanceInterval: TimeInterval = 30 * 60
    static let balanceInitialDelay: TimeInterval = 15

    private let device: SdkDeviceLocal
    private let logger: Logger
    private let queue = DispatchQueue(label: "network.ur.widget-snapshot", qos: .utility)

    private var subs: [SdkSubProtocol] = []
    private var writeTimer: DispatchSourceTimer?
    private var balanceTimer: DispatchSourceTimer?
    private var balanceCallback: SubscriptionBalanceCallback?

    private var accumulator: WidgetThroughputAccumulator
    private var location: WidgetLocationSnapshot?
    private var providers: [WidgetProviderSnapshot] = []
    private var providing = false
    private var provideMode: String? = nil
    private var active = false
    private var lastWritten: WidgetTunnelSnapshot?
    /// Mirrors WidgetPreviewVisibility; owned by `queue`.
    private var previewVisible = false
    /// The writer the process-wide Darwin observers forward to.
    private static weak var current: WidgetSnapshotWriter?
    private static var previewObserverRegistered = false
    private static var refreshObserverRegistered = false
    /// When a widget's refresh request was last served; owned by `queue`.
    private var lastRefreshWriteAt: Date?

    private var contracts = ContractTracker()
    private var contractRefreshPending = false
    private var lastContractRefreshAt: Date?

    // one throttle per widget kind, so every reason to reload shares that
    // kind's budget instead of each keeping its own
    private let dashboardReload: WidgetReloadThrottle
    private let globeReload: WidgetReloadThrottle
    private let contractsReload: WidgetReloadThrottle

    init(device: SdkDeviceLocal, logger: Logger) {
        self.device = device
        self.logger = logger
        // resume the hour of history the previous tunnel session wrote, so a
        // restart does not flatten the chart
        self.accumulator = WidgetThroughputAccumulator(
            resuming: WidgetSnapshotStore.loadTunnel()?.throughput ?? .empty
        )
        self.dashboardReload = WidgetReloadThrottle(interval: Self.reloadBackstopInterval) {
            WidgetRefresh.reloadDashboard()
        }
        self.globeReload = WidgetReloadThrottle(interval: Self.reloadBackstopInterval) {
            WidgetRefresh.reloadProviderGlobe()
        }
        self.contractsReload = WidgetReloadThrottle(interval: Self.reloadBackstopInterval) {
            WidgetRefresh.reloadContracts()
        }
    }

    // MARK: Lifecycle

    /// Subscribe to the device and start the write and balance timers. Call
    /// once the device exists; the first snapshot is written by
    /// `tunnelStarted()`.
    func start() {
        queue.async { [self] in
            active = true
            location = Self.locationSnapshot(device.getConnectLocation())
            providing = device.getProvideEnabled()
            provideMode = device.getProvideControlMode()
            providers = Self.providerSnapshots(Self.orderedProviders(device))
            if let stats = device.getPacketStats() {
                accumulator.recordClient(
                    egress: stats.remoteEgressByteCount, ingress: stats.remoteIngressByteCount,
                    egressPackets: stats.remoteEgressPacketCount, ingressPackets: stats.remoteIngressPacketCount
                )
            }
            if let stats = device.getProviderPacketStats() {
                accumulator.recordProvider(
                    egress: stats.localEgressByteCount + stats.blockEgressByteCount,
                    ingress: stats.localIngressByteCount + stats.blockIngressByteCount,
                    egressPackets: stats.localEgressPacketCount + stats.blockEgressPacketCount,
                    ingressPackets: stats.localIngressPacketCount + stats.blockIngressPacketCount
                )
            }

            if let sub = device.add(WidgetConnectLocationListener { [weak self] location in
                self?.queue.async {
                    guard let self, self.active else { return }
                    let snapshot = Self.locationSnapshot(location)
                    guard snapshot != self.location else { return }
                    self.location = snapshot
                    self.write()
                    self.dashboardReload.request(urgent: true)
                    self.globeReload.request(urgent: true)
                }
            }) {
                subs.append(sub)
            }
            if let sub = device.add(WidgetProvideListener { [weak self] provideEnabled in
                self?.queue.async {
                    guard let self, self.active, self.providing != provideEnabled else { return }
                    self.providing = provideEnabled
                    self.write()
                    self.dashboardReload.request(urgent: true)
                }
            }) {
                subs.append(sub)
            }
            if let sub = device.add(WidgetProvideControlModeListener { [weak self] mode in
                self?.queue.async {
                    guard let self, self.active, self.provideMode != mode else { return }
                    self.provideMode = mode
                    self.write()
                    self.dashboardReload.request(urgent: true)
                }
            }) {
                subs.append(sub)
            }
            if let sub = device.add(WidgetConnectedProvidersListener { [weak self] in
                self?.queue.async {
                    guard let self, self.active else { return }
                    let snapshot = Self.providerSnapshots(Self.orderedProviders(self.device))
                    guard snapshot != self.providers else { return }
                    self.providers = snapshot
                    self.write()
                    // the globe follows providers joining and leaving, like the
                    // app's provider details view, within the reload budget
                    self.globeReload.request()
                }
            }) {
                subs.append(sub)
            }
            if let sub = device.add(WidgetPacketStatsListener { [weak self] stats in
                guard let stats else { return }
                let egress = stats.remoteEgressByteCount
                let ingress = stats.remoteIngressByteCount
                let egressPackets = stats.remoteEgressPacketCount
                let ingressPackets = stats.remoteIngressPacketCount
                self?.queue.async {
                    guard let self, self.active else { return }
                    self.accumulator.recordClient(
                        egress: egress, ingress: ingress,
                        egressPackets: egressPackets, ingressPackets: ingressPackets
                    )
                }
            }) {
                subs.append(sub)
            }
            if let sub = device.addProviderPacketStatsChangeListener(WidgetPacketStatsListener { [weak self] stats in
                guard let stats else { return }
                let egress = stats.localEgressByteCount + stats.blockEgressByteCount
                let ingress = stats.localIngressByteCount + stats.blockIngressByteCount
                let egressPackets = stats.localEgressPacketCount + stats.blockEgressPacketCount
                let ingressPackets = stats.localIngressPacketCount + stats.blockIngressPacketCount
                self?.queue.async {
                    guard let self, self.active else { return }
                    self.accumulator.recordProvider(
                        egress: egress, ingress: ingress,
                        egressPackets: egressPackets, ingressPackets: ingressPackets
                    )
                }
            }) {
                subs.append(sub)
            }

            // client contracts: one event per contract change, coalesced into
            // a re-read of both lists
            let contractListener = WidgetContractDetailsListener { [weak self] in
                self?.queue.async {
                    self?.scheduleContractRefresh()
                }
            }
            if let sub = device.addEgressContractDetailsChangeListener(contractListener) {
                subs.append(sub)
            }
            if let sub = device.addIngressContractDetailsChangeListener(contractListener) {
                subs.append(sub)
            }
            refreshContracts()

            let writeTimer = DispatchSource.makeTimerSource(queue: queue)
            writeTimer.schedule(deadline: .now() + Self.writeInterval, repeating: Self.writeInterval, leeway: .seconds(5))
            writeTimer.setEventHandler { [weak self] in
                guard let self, self.active else { return }
                if self.previewVisible && !WidgetPreviewVisibility.isVisible {
                    // the app died with the previews open: the mark expired
                    self.applyPreviewVisibility()
                }
                // a darwin notification is not queued for a suspended
                // process, so a tap made while this one was frozen is served
                // here instead of being lost
                if WidgetSnapshotRefreshRequest.consume() {
                    self.serveRefreshRequest()
                    return
                }
                if self.write() {
                    self.dashboardReload.request()
                    self.globeReload.request()
                    self.contractsReload.request()
                }
            }
            writeTimer.resume()
            self.writeTimer = writeTimer

            Self.current = self
            Self.registerPreviewObserver()
            Self.registerRefreshObserver()
            applyPreviewVisibility()

            let balanceTimer = DispatchSource.makeTimerSource(queue: queue)
            balanceTimer.schedule(
                deadline: .now() + Self.balanceInitialDelay, repeating: Self.balanceInterval, leeway: .seconds(60)
            )
            balanceTimer.setEventHandler { [weak self] in
                self?.refreshBalance()
            }
            balanceTimer.resume()
            self.balanceTimer = balanceTimer
        }
    }

    /// The tunnel is up: publish and re-render every surface at once.
    func tunnelStarted() {
        queue.async { [self] in
            guard active else { return }
            write()
            WidgetRefresh.reloadControl()
            dashboardReload.request(urgent: true)
            globeReload.request(urgent: true)
            contractsReload.request(urgent: true)
        }
    }

    /// The tunnel is going down. Writes the snapshot as inactive (keeping
    /// the last hour of buckets for the chart) and re-renders every surface.
    /// Synchronous: the process may be reaped right after stopTunnel returns.
    func tunnelStopped() {
        queue.sync { [self] in
            guard active else { return }
            active = false
            teardown()
            write(active: false)
            WidgetRefresh.reloadAll()
        }
    }

    /// Release listeners and timers without writing (a superseded start).
    func close() {
        queue.sync { [self] in
            active = false
            teardown()
        }
    }

    private func teardown() {
        if Self.current === self {
            Self.current = nil
        }
        previewVisible = false
        for sub in subs {
            sub.close()
        }
        subs.removeAll()
        writeTimer?.cancel()
        writeTimer = nil
        balanceTimer?.cancel()
        balanceTimer = nil
        dashboardReload.cancel()
        globeReload.cancel()
        contractsReload.cancel()
    }

    // MARK: Preview visibility

    /// One Darwin observer per process; the callback is a C function pointer,
    /// so it reaches the live writer through `current`.
    private static func registerPreviewObserver() {
        guard !previewObserverRegistered else { return }
        previewObserverRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                WidgetSnapshotWriter.current?.previewVisibilityChanged()
            },
            WidgetPreviewVisibility.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: Refresh requests

    /// One Darwin observer per process, the same shape as the preview one.
    private static func registerRefreshObserver() {
        guard !refreshObserverRegistered else { return }
        refreshObserverRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                WidgetSnapshotWriter.current?.snapshotRefreshRequested()
            },
            WidgetSnapshotRefreshRequest.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func snapshotRefreshRequested() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            // the floor is checked BEFORE consuming: a request left on disk is
            // served by the next write-timer tick, where consuming and then
            // bailing would swallow the tap and leave the widget waiting out
            // its timeout for a write that was never going to come
            let elapsed = self.lastRefreshWriteAt.map { Date().timeIntervalSince($0) } ?? .infinity
            guard Self.refreshRequestFloor <= elapsed else { return }
            guard WidgetSnapshotRefreshRequest.consume() else { return }
            self.serveRefreshRequest()
        }
    }

    /// Publish now, for a widget that is waiting on it.
    ///
    /// Deliberately asks for NO reload: the widget process already requested
    /// one, and a reload caused by an in-widget intent is not charged against
    /// the budget while one requested from here is. Contracts are re-read
    /// first so the one write carries a current membership rather than the
    /// last cached one.
    private func serveRefreshRequest() {
        lastRefreshWriteAt = Date()
        refreshContracts()
        write()
    }

    private func previewVisibilityChanged() {
        queue.async { [weak self] in
            self?.applyPreviewVisibility()
        }
    }

    /// Re-reads the mark and moves the write timer to the matching cadence.
    /// Becoming visible publishes right away and refreshes what the previews
    /// show that the routine cadence leaves stale: the contracts and the
    /// balance.
    private func applyPreviewVisibility() {
        guard active else { return }
        let visible = WidgetPreviewVisibility.isVisible
        guard visible != previewVisible else { return }
        previewVisible = visible
        let interval = visible ? Self.previewWriteInterval : Self.writeInterval
        writeTimer?.schedule(
            deadline: .now() + interval, repeating: interval,
            leeway: visible ? .milliseconds(500) : .seconds(5)
        )
        if visible {
            write()
            scheduleContractRefresh()
            refreshBalance()
        }
    }

    // MARK: Contracts

    private func scheduleContractRefresh() {
        guard active, !contractRefreshPending else { return }
        let elapsed = lastContractRefreshAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, Self.contractRefreshInterval - elapsed)
        contractRefreshPending = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.contractRefreshPending = false
            self.refreshContracts()
        }
    }

    private func refreshContracts() {
        guard active else { return }
        lastContractRefreshAt = Date()
        let membershipChanged = contracts.update(
            egress: device.getEgressContractDetails(),
            ingress: device.getIngressContractDetails()
        )
        if membershipChanged {
            write()
            // peers and contracts coming and going is what the contracts
            // widget shows; rates and byte counts ride the routine cadence
            contractsReload.request()
        }
    }

    // MARK: Snapshot

    /// Writes the current state; returns whether anything changed.
    @discardableResult
    private func write(active: Bool? = nil) -> Bool {
        let snapshot = WidgetTunnelSnapshot(
            updatedAt: Date(),
            tunnelActive: active ?? self.active,
            providing: providing,
            provideMode: provideMode,
            location: location,
            providers: providers,
            throughput: accumulator.snapshot,
            contracts: contracts.peers(limit: Self.contractPeerLimit, stackLimit: Self.contractStackLimit)
        )
        var comparable = snapshot
        comparable.updatedAt = lastWritten?.updatedAt ?? snapshot.updatedAt
        let changed = comparable != lastWritten
        if WidgetSnapshotStore.save(snapshot) {
            lastWritten = snapshot
        } else {
            logger.error("[WidgetSnapshotWriter] failed to write the tunnel snapshot")
        }
        return changed
    }

    private func refreshBalance() {
        guard active, let api = device.getApi() else { return }
        let callback = SubscriptionBalanceCallback { [weak self] result in
            guard let self, let result else { return }
            self.queue.async {
                let snapshot = WidgetBalanceSnapshot(
                    updatedAt: Date(),
                    startBalanceByteCount: result.startBalanceByteCount,
                    balanceByteCount: result.balanceByteCount,
                    openTransferByteCount: result.openTransferByteCount,
                    isPro: result.currentSubscription != nil
                )
                if WidgetSnapshotStore.save(snapshot) {
                    // the balance bar is the dashboard's alone
                    self.dashboardReload.request()
                }
            }
        }
        balanceCallback = callback
        api.subscriptionBalance(callback)
    }

    // MARK: Mapping

    static func locationSnapshot(_ location: SdkConnectLocation?) -> WidgetLocationSnapshot? {
        guard let location else { return nil }
        let countryCode = location.countryCode.lowercased()
        return WidgetLocationSnapshot(
            name: location.name,
            countryCode: countryCode,
            city: location.city,
            region: location.region,
            country: location.country,
            bestAvailable: location.connectLocationId?.bestAvailable ?? false,
            networkPeer: location.networkPeer,
            providerCount: Int(location.providerCount),
            colorHex: countryCode.isEmpty ? "" : SdkGetColorHex(countryCode)
        )
    }

    /// The connected providers in the app's display order — west to east
    /// about their centroid, unplottable last — computed by the SDK, the same
    /// code the provider details view uses.
    static func orderedProviders(_ device: SdkDeviceLocal) -> SdkConnectedProviderLocationList? {
        SdkOrderConnectedProviderLocations(device.getConnectedProviderLocations())
    }

    static func providerSnapshots(_ list: SdkConnectedProviderLocationList?) -> [WidgetProviderSnapshot] {
        guard let list else { return [] }
        var providers: [WidgetProviderSnapshot] = []
        for i in 0..<list.len() {
            guard let item = list.get(i) else { continue }
            // the same plot rule as the app: city centroid, else region
            var lat: Double? = nil
            var lon: Double? = nil
            if item.hasCityCoordinates {
                lat = item.cityLat
                lon = item.cityLon
            } else if item.hasRegionCoordinates {
                lat = item.regionLat
                lon = item.regionLon
            }
            let countryCode = item.countryCode.lowercased()
            providers.append(WidgetProviderSnapshot(
                id: item.clientId?.idStr ?? "\(i)",
                country: item.country,
                countryCode: countryCode,
                region: item.region,
                city: item.city,
                lat: lat,
                lon: lon,
                connectedSinceMillis: item.connectedSinceMillis,
                colorHex: countryCode.isEmpty ? "" : SdkGetColorHex(countryCode)
            ))
        }
        return providers
    }

}

// MARK: - Contract tracking

/// Groups this device's open client contracts by peer into send / receive
/// stacks, the way the SDK's ContractDetailsViewController does for the app
/// (that controller is not part of the extension's SDK slice). Order within a
/// stack is newest first by first sighting; a peer's byte counts accumulate
/// across its contracts for as long as it has any open, and its last
/// activity is the last time any of its contracts carried a positive bit rate.
struct ContractTracker {

    private struct Seen {
        var direction: Direction
        var peerId: String
        var sequence: Int64
        var lastUsedByteCount: Int64
    }

    private enum Direction { case send, receive }

    private struct PeerState {
        var closedSendByteCount: Int64 = 0
        var closedReceiveByteCount: Int64 = 0
        var lastActivityMillis: Int64 = 0
    }

    private var seen: [String: Seen] = [:]
    private var peerState: [String: PeerState] = [:]
    private var sequence: Int64 = 0
    private var current: [WidgetContractPeerSnapshot] = []

    /// Re-reads both lists. Returns whether the set of peers or contracts
    /// changed (as opposed to only their numbers).
    mutating func update(egress: SdkContractDetailsList?, ingress: SdkContractDetailsList?) -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var sendByPeer: [String: [(WidgetContractSnapshot, Int64)]] = [:]
        var receiveByPeer: [String: [(WidgetContractSnapshot, Int64)]] = [:]
        var live: Set<String> = []

        func ingest(_ list: SdkContractDetailsList?, direction: Direction) {
            guard let list else { return }
            for i in 0..<list.len() {
                guard let details = list.get(i),
                      details.status != "closed",
                      let contractId = details.contractId?.idStr, !contractId.isEmpty,
                      let path = details.contractTransferPath else {
                    continue
                }
                // an egress contract sends to its destination; an ingress
                // contract receives from its source
                let peerId = (direction == .send ? path.destinationId : path.sourceId)?.idStr ?? ""
                guard !peerId.isEmpty else { continue }
                live.insert(contractId)
                if seen[contractId] == nil {
                    sequence += 1
                    seen[contractId] = Seen(
                        direction: direction, peerId: peerId, sequence: sequence,
                        lastUsedByteCount: details.contractUsedByteCount
                    )
                }
                seen[contractId]?.lastUsedByteCount = details.contractUsedByteCount
                let entry = WidgetContractSnapshot(
                    id: contractId,
                    usedByteCount: details.contractUsedByteCount,
                    totalByteCount: details.contractByteCount,
                    bitRate: Int64(details.contractBitRate),
                    hasStream: Self.isStream(path.streamId)
                )
                if 0 < entry.bitRate {
                    peerState[peerId, default: PeerState()].lastActivityMillis = now
                }
                let order = seen[contractId]?.sequence ?? 0
                if direction == .send {
                    sendByPeer[peerId, default: []].append((entry, order))
                } else {
                    receiveByPeer[peerId, default: []].append((entry, order))
                }
            }
        }
        ingest(egress, direction: .send)
        ingest(ingress, direction: .receive)

        // contracts that closed: fold their bytes into the peer's run total
        for (contractId, info) in seen where !live.contains(contractId) {
            var state = peerState[info.peerId, default: PeerState()]
            if info.direction == .send {
                state.closedSendByteCount += info.lastUsedByteCount
            } else {
                state.closedReceiveByteCount += info.lastUsedByteCount
            }
            peerState[info.peerId] = state
            seen[contractId] = nil
        }

        let peerIds = Set(sendByPeer.keys).union(receiveByPeer.keys)
        // peers with nothing open any more end their run
        for peerId in peerState.keys where !peerIds.contains(peerId) {
            peerState[peerId] = nil
        }

        var peers: [WidgetContractPeerSnapshot] = []
        for peerId in peerIds {
            let state = peerState[peerId, default: PeerState()]
            let send = (sendByPeer[peerId] ?? []).sorted { $0.1 > $1.1 }.map { $0.0 }
            let receive = (receiveByPeer[peerId] ?? []).sorted { $0.1 > $1.1 }.map { $0.0 }
            peers.append(WidgetContractPeerSnapshot(
                id: peerId,
                send: send,
                receive: receive,
                sendByteCount: state.closedSendByteCount + send.reduce(0) { $0 + $1.usedByteCount },
                receiveByteCount: state.closedReceiveByteCount + receive.reduce(0) { $0 + $1.usedByteCount },
                lastActivityMillis: state.lastActivityMillis
            ))
        }
        // most relevant first: moving bytes now, then most recently, then most bytes
        peers.sort { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.lastActivityMillis != b.lastActivityMillis { return a.lastActivityMillis > b.lastActivityMillis }
            let aBytes = a.sendByteCount + a.receiveByteCount
            let bBytes = b.sendByteCount + b.receiveByteCount
            if aBytes != bBytes { return aBytes > bBytes }
            return a.id < b.id
        }

        let membershipChanged = Self.membership(current) != Self.membership(peers)
        current = peers
        return membershipChanged
    }

    func peers(limit: Int, stackLimit: Int) -> [WidgetContractPeerSnapshot] {
        current.prefix(limit).map { peer in
            var trimmed = peer
            trimmed.send = Array(peer.send.prefix(stackLimit))
            trimmed.receive = Array(peer.receive.prefix(stackLimit))
            return trimmed
        }
    }

    private static func membership(_ peers: [WidgetContractPeerSnapshot]) -> [String] {
        peers.map { peer in
            peer.id + ":" + peer.send.map(\.id).joined(separator: ",") + "|" + peer.receive.map(\.id).joined(separator: ",")
        }
    }

    /// The SDK's stream test: a non-nil, non-zero stream id.
    private static func isStream(_ streamId: SdkId?) -> Bool {
        guard let idStr = streamId?.idStr, !idStr.isEmpty else { return false }
        return idStr.contains { $0 != "0" && $0 != "-" }
    }
}

// MARK: - SDK listener adapters

private final class WidgetContractDetailsListener: NSObject, SdkContractDetailsChangeListenerProtocol {
    private let c: () -> Void
    init(c: @escaping () -> Void) { self.c = c }
    func contractDetailsChanged(_ contractDetails: SdkContractDetails?) { c() }
}

private final class WidgetConnectLocationListener: NSObject, SdkConnectLocationChangeListenerProtocol {
    private let c: (SdkConnectLocation?) -> Void
    init(c: @escaping (SdkConnectLocation?) -> Void) { self.c = c }
    func connectLocationChanged(_ location: SdkConnectLocation?) { c(location) }
}

private final class WidgetProvideListener: NSObject, SdkProvideChangeListenerProtocol {
    private let c: (Bool) -> Void
    init(c: @escaping (Bool) -> Void) { self.c = c }
    func provideChanged(_ provideEnabled: Bool) { c(provideEnabled) }
}

private final class WidgetProvideControlModeListener: NSObject, SdkProvideControlModeChangeListenerProtocol {
    private let c: (String?) -> Void
    init(c: @escaping (String?) -> Void) { self.c = c }
    func provideControlModeChanged(_ provideControlMode: String?) { c(provideControlMode) }
}

private final class WidgetConnectedProvidersListener: NSObject, SdkConnectedProviderLocationChangeListenerProtocol {
    private let c: () -> Void
    init(c: @escaping () -> Void) { self.c = c }
    func connectedProviderLocationsChanged() { c() }
}

private final class WidgetPacketStatsListener: NSObject, SdkPacketStatsChangeListenerProtocol {
    private let c: (SdkPacketStats?) -> Void
    init(c: @escaping (SdkPacketStats?) -> Void) { self.c = c }
    func packetStatsChanged(_ packetStats: SdkPacketStats?) { c(packetStats) }
}

private final class SubscriptionBalanceCallback: NSObject, SdkSubscriptionBalanceCallbackProtocol {
    private let c: (SdkSubscriptionBalanceResult?) -> Void
    init(c: @escaping (SdkSubscriptionBalanceResult?) -> Void) { self.c = c }
    func result(_ result: SdkSubscriptionBalanceResult?, err: Error?) { c(err == nil ? result : nil) }
}
