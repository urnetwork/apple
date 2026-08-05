//
//  ReliabilityStore.swift
//  URnetwork
//
//  Created by Claude on 8/4/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * Read-only snapshot of the reliability behavior currently in effect on the
 * extension device: the runtime override when one is set, the shipped
 * defaults otherwise. Display only -- edits never round-trip through this
 * snapshot (see `ReliabilityStore.updateSettings`), so a field added on the
 * sdk side can never be zeroed by an app that does not know about it yet.
 */
struct ReliabilitySettings: Equatable {
    var udpTeardownSignal: Bool = false
    var quicRebindOnExitLoss: Bool = false
    var dialFailureRerace: Bool = false
    var tcpCollapseMaxHoldMillis: Int64 = 0
    var sendStallTimeoutMillis: Int64 = 0
    var clusterAffinityFallback: Bool = false
    var serverNameAffinityBridge: Bool = false
    var sequenceIdleTimeoutMillis: Int64 = 0
    var tcpSequenceIdleTimeoutMillis: Int64 = 0
    var blackholeReceiveTimeoutMillis: Int64 = 0
    var maxFlowsPerExit: Int32 = 0
    var affinityStickyPastCap: Bool = false
    var quarantineGroupFollow: Bool = false
    var groupFollowWindowMillis: Int64 = 0
    var uplinkStalenessGateMillis: Int64 = 0
    var softVerdictDemote: Bool = false
    var removalBudgetCount: Int32 = 0
    var removalBudgetWindowMillis: Int64 = 0
    var standingReserve: Bool = false
    var effectiveTierSelection: Bool = false
    var minBlackholeDestinations: Int32 = 0
    var blackholeLoadCorroboration: Int32 = 0
    var providerProbe: Bool = false
    var probeTimeoutMillis: Int64 = 0
    var probeSampleHostCount: Int32 = 0
    var probeSilenceWarnStreak: Int32 = 0
    var evaluationPoolMultiple: Int32 = 0
    var formationPollTimeoutMillis: Int64 = 0
    var busyProbe: Bool = false
    var busyProbeBudgetMillis: Int64 = 0
    var schedulerPauseToleranceMillis: Int64 = 0
    var schedulerPauseRecoveryTimeoutMillis: Int64 = 0
    var blackholeConnectComparativeTimeoutMillis: Int64 = 0
    var heartbeatIntervalMillis: Int64 = 0

    init() {}

    init(_ settings: SdkReliabilitySettings) {
        udpTeardownSignal = settings.udpTeardownSignal
        quicRebindOnExitLoss = settings.quicRebindOnExitLoss
        dialFailureRerace = settings.dialFailureRerace
        tcpCollapseMaxHoldMillis = settings.tcpCollapseMaxHoldMillis
        sendStallTimeoutMillis = settings.sendStallTimeoutMillis
        clusterAffinityFallback = settings.clusterAffinityFallback
        serverNameAffinityBridge = settings.serverNameAffinityBridge
        sequenceIdleTimeoutMillis = settings.sequenceIdleTimeoutMillis
        tcpSequenceIdleTimeoutMillis = settings.tcpSequenceIdleTimeoutMillis
        blackholeReceiveTimeoutMillis = settings.blackholeReceiveTimeoutMillis
        maxFlowsPerExit = settings.maxFlowsPerExit
        affinityStickyPastCap = settings.affinityStickyPastCap
        quarantineGroupFollow = settings.quarantineGroupFollow
        groupFollowWindowMillis = settings.groupFollowWindowMillis
        uplinkStalenessGateMillis = settings.uplinkStalenessGateMillis
        softVerdictDemote = settings.softVerdictDemote
        removalBudgetCount = settings.removalBudgetCount
        removalBudgetWindowMillis = settings.removalBudgetWindowMillis
        standingReserve = settings.standingReserve
        effectiveTierSelection = settings.effectiveTierSelection
        minBlackholeDestinations = settings.minBlackholeDestinations
        blackholeLoadCorroboration = settings.blackholeLoadCorroboration
        providerProbe = settings.providerProbe
        probeTimeoutMillis = settings.probeTimeoutMillis
        probeSampleHostCount = settings.probeSampleHostCount
        probeSilenceWarnStreak = settings.probeSilenceWarnStreak
        evaluationPoolMultiple = settings.evaluationPoolMultiple
        formationPollTimeoutMillis = settings.formationPollTimeoutMillis
        busyProbe = settings.busyProbe
        busyProbeBudgetMillis = settings.busyProbeBudgetMillis
        schedulerPauseToleranceMillis = settings.schedulerPauseToleranceMillis
        schedulerPauseRecoveryTimeoutMillis = settings.schedulerPauseRecoveryTimeoutMillis
        blackholeConnectComparativeTimeoutMillis = settings.blackholeConnectComparativeTimeoutMillis
        heartbeatIntervalMillis = settings.heartbeatIntervalMillis
    }
}

/**
 * Counters snapshot: what provider failures have cost since the last reset.
 * The reliability controls are judged against these -- an A/B run is reset,
 * set the config, drive the same workload, read the numbers back.
 */
struct ReliabilityMetrics: Equatable {
    var flowsOpened: Int64 = 0
    var exitLossEvents: Int64 = 0
    var flowsLostToExit: Int64 = 0
    var maxFlowsLostInOneEvent: Int64 = 0
    var meanFlowsLostPerExitLoss: Double = 0
    var recoveryCount: Int64 = 0
    var recoveryMissed: Int64 = 0
    var recoveryMeanMillis: Int64 = 0
    var recoveryMaxMillis: Int64 = 0
    var recoveryPending: Int32 = 0
    var dialFailuresIntercepted: Int64 = 0
    var flowsReraced: Int64 = 0
    var flowsRebound: Int64 = 0
    var rebindsAccepted: Int64 = 0
    var rebindsRedialed: Int64 = 0
    var verdictsHeldUplinkStale: Int64 = 0
    var verdictsHeldTransportDown: Int64 = 0
    var removalsDeferred: Int64 = 0
    var probesSent: Int64 = 0
    var probesAnswered: Int64 = 0
    var providersQualified: Int64 = 0
    var busyProbesSent: Int64 = 0
    var busyProbesAcquitted: Int64 = 0
    var schedulerPausesDetected: Int64 = 0
    var groupsFollowed: Int64 = 0
    var groupsScattered: Int64 = 0

    init() {}

    init(_ metrics: SdkReliabilityMetrics) {
        flowsOpened = metrics.flowsOpened
        exitLossEvents = metrics.exitLossEvents
        flowsLostToExit = metrics.flowsLostToExit
        maxFlowsLostInOneEvent = metrics.maxFlowsLostInOneEvent
        meanFlowsLostPerExitLoss = metrics.meanFlowsLostPerExitLoss
        recoveryCount = metrics.recoveryCount
        recoveryMissed = metrics.recoveryMissed
        recoveryMeanMillis = metrics.recoveryMeanMillis
        recoveryMaxMillis = metrics.recoveryMaxMillis
        recoveryPending = metrics.recoveryPending
        dialFailuresIntercepted = metrics.dialFailuresIntercepted
        flowsReraced = metrics.flowsReraced
        flowsRebound = metrics.flowsRebound
        rebindsAccepted = metrics.rebindsAccepted
        rebindsRedialed = metrics.rebindsRedialed
        verdictsHeldUplinkStale = metrics.verdictsHeldUplinkStale
        verdictsHeldTransportDown = metrics.verdictsHeldTransportDown
        removalsDeferred = metrics.removalsDeferred
        probesSent = metrics.probesSent
        probesAnswered = metrics.probesAnswered
        providersQualified = metrics.providersQualified
        busyProbesSent = metrics.busyProbesSent
        busyProbesAcquitted = metrics.busyProbesAcquitted
        schedulerPausesDetected = metrics.schedulerPausesDetected
        groupsFollowed = metrics.groupsFollowed
        groupsScattered = metrics.groupsScattered
    }
}

/**
 * One provider channel, as shown in the developer screen exit readout.
 */
struct ReliabilityExit: Identifiable, Equatable {
    let id: String
    // "quality", "speed", or "" for auto
    let windowType: String
    let warning: Bool
    let quarantined: Bool
    // WHY the exit is warned, named by the go side. Rendered verbatim so
    // causes added later ("silent", ...) display without an app update
    let warningCause: String
    let done: Bool
    let p2pOnly: Bool
    let flowCount: Int32
    let dialFailureCount: Int32
    let tier: Int32
    let effectiveTier: Int32
    let proven: Bool
    // seconds since last proven; -1 is never
    let probeAgeSeconds: Int64

    /**
     * nil for an exit with no client id. The go side always populates one, so
     * this is latent -- but an exit without an id is not addressable (migrate
     * parses it back into an Id) and substituting a fresh uuid would mint a
     * new ForEach identity on every 5s poll, rebuilding the row and sending
     * garbage to the bridge.
     */
    init?(_ exit: SdkExit) {
        guard let clientId = exit.clientId?.idStr, !clientId.isEmpty else {
            return nil
        }
        id = clientId
        windowType = exit.windowType
        warning = exit.warning
        quarantined = exit.quarantined
        warningCause = exit.warningCause
        done = exit.done
        p2pOnly = exit.p2pOnly
        flowCount = exit.flowCount
        dialFailureCount = exit.dialFailureCount
        tier = exit.tier
        effectiveTier = exit.effectiveTier
        proven = exit.proven
        probeAgeSeconds = exit.probeAgeSeconds
    }

    /**
     * A short label that actually distinguishes one exit from another. Client
     * ids are ULIDs: the leading characters encode creation time, and the
     * channels in a window are opened within milliseconds of each other, so a
     * leading substring renders every row identical. The entropy is in the
     * tail.
     */
    var label: String {
        String(id.suffix(8))
    }

    /**
     * The one-line state summary: window type, tier (with the effective-tier
     * demotion when selection has demoted the exit), the warning state by
     * name, and the lifecycle chips. The warning cause string passes through
     * verbatim -- new causes must display without an app update.
     */
    var stateLine: String {
        var parts: [String] = [windowType.isEmpty ? "auto" : windowType]

        // the platform's rank for this provider. only the best rank present is
        // raced until it is at the flow cap, so a tier above the minimum with
        // 0 flows is a spare, not a failure. effectiveTier is the rank
        // selection actually uses (tier plus live demerits); when it differs
        // the exit is demoted and "tier N→M" makes that visible
        var tierPart = "tier \(tier)"
        if tier < effectiveTier {
            tierPart += "→\(effectiveTier)"
        }
        parts.append(tierPart)

        // "benched" is a quarantine (a soft verdict held against a loaded
        // exit -- it stops taking new placements while its flows keep running,
        // and receive progress acquits it); otherwise the resize pass's cause
        // string, verbatim
        if quarantined {
            parts.append("benched")
        } else if warning {
            parts.append(warningCause.isEmpty ? "warned" : warningCause)
        }
        if done {
            parts.append("done")
        }
        if p2pOnly {
            parts.append("p2p")
        }
        // a probe pass (or the exit's own traffic) proved this provider dials
        // real destinations within the qualification window. Absence of the
        // chip is "not yet proven", never "bad"
        if proven {
            parts.append("proven")
        }
        return parts.joined(separator: " · ")
    }
}

private func mapExits(_ list: SdkExitList?) -> [ReliabilityExit] {
    guard let list = list else {
        return []
    }
    var exits: [ReliabilityExit] = []
    exits.reserveCapacity(list.len())
    for i in 0..<list.len() {
        if let exit = list.get(i), let row = ReliabilityExit(exit) {
            exits.append(row)
        }
    }
    return exits
}

/**
 * Publishes the live reliability surface for the developer screen: the
 * effective settings, the counters, and the per-exit readout.
 *
 * Every DeviceRemote call here is a synchronous rpc round trip to the packet
 * tunnel extension, so they all run off the main actor, serialized on one
 * queue (see `bridgeQueue`). The screen's 5s poll runs only while the screen
 * is visible (`setActive`) and a device is set; everything tolerates
 * `device == nil` (tunnel down) and a replaced device object (extension
 * restart) mid-flight.
 *
 * `settings` is nil whenever the extension has no multi client to override --
 * which on iOS is NOT the same as "no device": the DeviceRemote is created at
 * login and outlives every tunnel session, so a non-nil device says nothing
 * about whether there is anything to configure.
 */
@MainActor
class ReliabilityStore: ObservableObject {

    /**
     * how often the developer screen re-reads the reliability surface while
     * open. The counters move on their own -- a stalled exit takes seconds to
     * be detected -- and without polling a stale zero reads as "no provider
     * failures" rather than "nothing measured yet"
     */
    static let pollInterval: TimeInterval = 5

    @Published private(set) var settings: ReliabilitySettings? = nil
    @Published private(set) var metrics: ReliabilityMetrics? = nil
    @Published private(set) var exits: [ReliabilityExit] = []
    @Published private(set) var lastAction: String? = nil

    /**
     * nil settings means there is no multi client behind the bridge -- the
     * tunnel is down, so the controls have nothing to act on and the screen
     * shows a connect hint rather than reporting defaults that are not in
     * force. This is the ONLY honest connected signal on iOS: the device
     * itself is created at login and exists whether or not the tunnel is up.
     */
    var connected: Bool {
        settings != nil
    }

    private var device: SdkDeviceRemote?

    /**
     * Every DeviceRemote call runs here: off the main thread, and serialized.
     *
     * Serialization is load-bearing, not hygiene. A settings mutation is a
     * read-modify-write of the FULL struct, so two overlapping mutations lose
     * a field -- the second reads before the first has written, then reverts
     * it with its own full-struct write. Reads share the queue too, so a poll
     * can never publish a snapshot it read halfway through a write.
     */
    private let bridgeQueue = DispatchQueue(label: "com.urnetwork.ReliabilityStore.bridge")

    // true while the developer screen is visible
    private var active = false
    private var pollTimer: Timer?

    // bumped on every setup/reset so a refresh that started against an old
    // device (or before a reset) can never publish over newer state
    private var generation = 0

    deinit {
        pollTimer?.invalidate()
    }

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        refresh()
        if active {
            startPolling()
        }
    }

    func reset() {
        generation += 1
        stopPolling()
        device = nil

        settings = nil
        metrics = nil
        exits = []
        lastAction = nil
    }

    /**
     * the developer screen reports its visibility; the poll runs only while
     * visible and is cancelled the moment the screen goes away
     */
    func setActive(_ nextActive: Bool) {
        guard active != nextActive else {
            return
        }
        active = nextActive
        if active {
            refresh()
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard active, device != nil, pollTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        // .common: the default mode is suspended while the form is being
        // scrolled, which is exactly when the counters are being watched
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        guard let device = self.device else {
            return
        }
        let generation = self.generation
        bridgeQueue.async { [weak self] in
            // each getter is a synchronous rpc round trip; never on the main
            // actor, and never overlapping a write on this queue.
            // settings is nil with no multi client behind the bridge; metrics
            // and the exit list honestly degrade to zeros and empty
            let settings = device.getReliabilitySettings().map { ReliabilitySettings($0) }
            let metrics = device.getReliabilityMetrics().map { ReliabilityMetrics($0) }
            let exits = mapExits(device.getExits())
            Task { @MainActor [weak self] in
                self?.publish(
                    settings: settings,
                    metrics: metrics,
                    exits: exits,
                    generation: generation
                )
            }
        }
    }

    private func publish(
        settings: ReliabilitySettings?,
        metrics: ReliabilityMetrics?,
        exits: [ReliabilityExit],
        generation: Int
    ) {
        guard generation == self.generation else {
            return
        }
        if settings != self.settings {
            self.settings = settings
        }
        if metrics != self.metrics {
            self.metrics = metrics
        }
        if exits != self.exits {
            self.exits = exits
        }
    }

    /**
     * Applies one settings change as a read-modify-write of the FULL settings
     * struct against a FRESH read from the device, serialized against every
     * other bridge call.
     *
     * Two traps meet here. Writing back a CACHED snapshot would apply a
     * partly-or-wholly zero-valued struct (`setReliabilitySettings` takes the
     * whole thing), silently turning every other reliability fix off. And a
     * fresh read of NIL means there is no multi client to override at all --
     * writing then would install an all-zero override that the bridge's sync
     * state re-applies when the extension starts, disabling the entire
     * reliability stack for the session. Neither is hypothetical on iOS,
     * where the device exists from login onward regardless of the tunnel.
     */
    func updateSettings(_ mutate: @escaping (SdkReliabilitySettings) -> Void) {
        guard let device = self.device else {
            return
        }
        let generation = self.generation
        bridgeQueue.async { [weak self] in
            guard let sdkSettings = device.getReliabilitySettings() else {
                // nothing to override; publish the nil so the screen falls
                // back to the connect hint instead of showing dead controls
                Task { @MainActor [weak self] in
                    self?.publishSettings(nil, generation: generation)
                }
                return
            }
            mutate(sdkSettings)
            device.setReliabilitySettings(sdkSettings)
            // read back the now-effective values so the ui reflects what the
            // device actually applied, not what was asked for
            let settings = device.getReliabilitySettings().map { ReliabilitySettings($0) }
            Task { @MainActor [weak self] in
                self?.publishSettings(settings, generation: generation)
            }
        }
    }

    private func publishSettings(_ settings: ReliabilitySettings?, generation: Int) {
        guard generation == self.generation else {
            return
        }
        if settings != self.settings {
            self.settings = settings
        }
    }

    /**
     * Clears the runtime override, restoring the shipped behavior -- the "put
     * it back" that makes every experiment undoable.
     */
    func resetSettings() {
        performAction("reset to shipped defaults") { device in
            _ = device.resetReliabilitySettings()
        }
    }

    /**
     * Zeroes the counters so a run starts clean. The A/B cycle is: reset, set
     * the config, drive the same workload, read the numbers back.
     */
    func resetMetrics() {
        performAction("reset measurements") { device in
            _ = device.resetReliabilityMetrics()
        }
    }

    /**
     * Hands one exit's movable (established QUIC) flows to live replacements
     * now, while the exit stays alive -- the drain-style hand-off on demand.
     * Nothing is killed: TCP and anything unplaceable keeps working where it
     * is.
     */
    func migrateExit(_ exit: ReliabilityExit) {
        performAction("migrate exit \(exit.label)") { device in
            _ = device.migrateExit(exit.id)
        }
    }

    // There is no per-exit probe: connect exposes only a full sweep
    // (ProbeAllExits), and the android developer screen has no per-row probe
    // either, so the sweep below is the whole probing surface.

    /**
     * Fires a qualification probe pass at every exit right now. Non-blocking;
     * the Probes counter moves as the passes complete. No-op while provider
     * probing is off.
     */
    func probeAllExits() {
        performAction("probe all exits") { device in
            _ = device.probeAllExits()
        }
    }

    /**
     * Fires the platform network-change path on demand -- the uplink epoch
     * reset and the transport kick a real wifi-to-cellular migration triggers
     * -- so the storm drill the uplink gate exists for is one tap instead of
     * physically moving between networks.
     */
    func simulateNetworkChange() {
        performAction("simulate network change") { device in
            _ = device.simulateNetworkChange()
        }
    }

    /**
     * Runs one action on the bridge queue and records it.
     *
     * `description` names what was ASKED FOR, never what happened: every
     * action on the frozen contract returns void, and each one is a silent
     * no-op when there is no multi client behind the rpc. Reporting
     * "Simulated network change" when nothing happened is exactly the
     * mechanism-with-no-field-observable-signal failure this screen exists to
     * catch. The counters and exit rows refreshed underneath are the evidence.
     */
    private func performAction(_ description: String, _ action: @escaping (SdkDeviceRemote) -> Void) {
        guard let device = self.device else {
            return
        }
        let generation = self.generation
        bridgeQueue.async { [weak self] in
            action(device)
            Task { @MainActor [weak self] in
                self?.finishAction(description, generation: generation)
            }
        }
    }

    private func finishAction(_ description: String, generation: Int) {
        guard generation == self.generation else {
            return
        }
        lastAction = "Requested: \(description)"
        refresh()
    }
}
