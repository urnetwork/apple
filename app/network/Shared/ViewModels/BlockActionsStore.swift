//
//  BlockActionsStore.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * A recent routing decision, aggregated per destination cluster
 */
struct BlockActionItem: Identifiable, Equatable {
    let id: String
    let time: Date
    // cluster hosts/ips that did NOT match an override (disjoint from the matched sets)
    let hosts: [String]
    let ips: [String]
    // the exact hosts/ips that matched an override rule, shown as green chips at the
    // front (disjoint from hosts/ips)
    let matchedHosts: [String]
    let matchedIps: [String]
    // the unmatched hosts collapsed to base names (SDK CollapseHostNames), shown as
    // white chips — the same collapse logic on every platform
    let hostBaseNames: [String]
    let block: Bool
    let local: Bool
    /**
     * the deciding override id, when an override determined the decision
     */
    let overrideId: String?
    let hasBlockOverride: Bool
    let hasRouteOverride: Bool
    let packetCount: Int
    let byteCount: Int64
    // short client ids of the exits CURRENTLY carrying flows to this
    // cluster's ips (live join against the flow table). One id is the normal
    // healthy shape; two ids on one row is a site split across egress IPs --
    // the exact event the affinity work exists to prevent
    let exitShortIds: [String]

    /**
     * every host name (matched + unmatched) and every ip (matched + unmatched)
     */
    var allHostNames: [String] {
        matchedHosts + hosts
    }
    var allIps: [String] {
        matchedIps + ips
    }

    /**
     * all host values that can be added to a split rule,
     * host names first (matched + unmatched, so the editor sees everything)
     */
    var hostValues: [String] {
        allHostNames + allIps
    }

    /**
     * count of unmatched ips, rendered as a single "X IPs" pill
     */
    var ipCount: Int {
        ips.count
    }
}

/**
 * What a site split rule does with the matching cluster's traffic.
 *
 * EXCLUDED routes the cluster locally, bypassing the tunnel; INCLUDED routes
 * it through the tunnel. PINNED is not routing at all: the cluster stays in
 * the tunnel like any other, but its flows are held to one stable exit, so
 * the site's api and its cdns present a single egress IP -- the fix for
 * sites whose images fail to load behind a multi-exit VPN.
 */
enum SplitRuleMode {
    case excluded
    case included
    case pinned

    func toSdkRouteOverride() -> SdkRouteOverride? {
        let route = SdkRouteOverride()
        switch self {
        case .excluded:
            route.local = true
        case .included:
            route.local = false
        case .pinned:
            route.local = false
            route.pin = true
        }
        return route
    }

    static func of(local: Bool, pin: Bool) -> SplitRuleMode {
        if local {
            return .excluded
        }
        if pin {
            return .pinned
        }
        return .included
    }
}

/**
 * A block action override ("split rule")
 */
struct SplitRuleItem: Identifiable, Equatable {
    let id: String
    // the raw host values (host names and ips mixed), for the editor
    let hosts: [String]
    // the rule's host names collapsed to base names (SDK CollapseHostNames), and its
    // exact ip values — both rendered as green chips in the row
    let hostBaseNames: [String]
    let ipValues: [String]
    let mode: SplitRuleMode
}

private class BlockActionsListener: NSObject, SdkBlockActionsListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func blockActionsChanged() {
        callback()
    }
}

private class BlockActionStatsListener: NSObject, SdkBlockActionStatsListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func blockActionStatsChanged() {
        callback()
    }
}

private class BlockActionOverridesListener: NSObject, SdkBlockActionOverridesChangeListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func blockActionOverridesChanged(_ blockActionOverrides: SdkBlockActionOverrideList?) {
        callback()
    }
}

/**
 * Publishes the live block action window, block stats, and the
 * block action overrides ("split rules")
 */
@MainActor
class BlockActionsStore: ObservableObject {

    /**
     * newest first
     */
    @Published private(set) var blockActions: [BlockActionItem] = []
    @Published private(set) var splitRules: [SplitRuleItem] = []
    @Published private(set) var allowedCount: Int = 0
    @Published private(set) var blockedCount: Int = 0

    private var device: SdkDeviceRemote?
    private var blockActionViewController: SdkBlockActionViewController?

    private var blockActionsSub: SdkSubProtocol?
    private var blockActionStatsSub: SdkSubProtocol?
    private var overridesSub: SdkSubProtocol?

    /**
     * the sdk override objects backing `splitRules`, used to rebuild
     * the full list on update
     */
    private var sdkOverrides: [SdkBlockActionOverride] = []

    /**
     * the live destination->exit attribution, joined onto each cluster's ips
     * in `updateBlockActions`: destination ip -> short client ids of the
     * exits CURRENTLY carrying flows to it, after any re-race or rebind
     */
    private var exitsByIp: [String: Set<String>] = [:]

    // the exit-attribution re-poll: flows re-race and rebind between
    // block-action events, so the join is refreshed on a slow tick as well,
    // active only while a consuming view is visible -- a row growing a
    // second exit chip mid-session is exactly the observation this feature
    // exists for
    private var exitAttributionTimer: Timer?
    private var exitAttributionActive = false
    private var exitAttributionRefreshing = false

    private static let exitAttributionInterval: TimeInterval = 5.0

    deinit {
        exitAttributionTimer?.invalidate()
    }

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device

        guard let blockActionViewController = device.openBlockActionViewController() else {
            return
        }
        self.blockActionViewController = blockActionViewController

        self.blockActionsSub = blockActionViewController.add(BlockActionsListener { [weak self] in
            DispatchQueue.main.async {
                self?.updateBlockActions()
                // new flows race and bind as routing decisions land, so the
                // attribution join re-pulls with the burst too
                self?.refreshExitAttribution()
            }
        })
        self.blockActionStatsSub = blockActionViewController.add(BlockActionStatsListener { [weak self] in
            DispatchQueue.main.async {
                self?.updateBlockStats()
            }
        })
        self.overridesSub = device.add(BlockActionOverridesListener { [weak self] in
            DispatchQueue.main.async {
                self?.updateOverrides()
            }
        })

        updateBlockActions()
        updateBlockStats()
        updateOverrides()
        refreshExitAttribution()
    }

    func reset() {
        blockActionsSub?.close()
        blockActionsSub = nil
        blockActionStatsSub?.close()
        blockActionStatsSub = nil
        overridesSub?.close()
        overridesSub = nil
        if let blockActionViewController {
            if let device {
                device.close(blockActionViewController)
            } else {
                blockActionViewController.close()
            }
        }
        blockActionViewController = nil
        device = nil

        blockActions = []
        splitRules = []
        sdkOverrides = []
        allowedCount = 0
        blockedCount = 0
        exitsByIp = [:]
    }

    /**
     * Runs the exit-attribution re-poll only while a consuming view is
     * visible; the join is a pull into the extension, so there is no reason
     * to keep it fresh with nothing rendering it
     */
    func setExitAttributionActive(_ nextActive: Bool) {
        guard exitAttributionActive != nextActive else {
            return
        }
        exitAttributionActive = nextActive
        if nextActive {
            refreshExitAttribution()
            exitAttributionTimer = Timer.scheduledTimer(
                withTimeInterval: Self.exitAttributionInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshExitAttribution()
                }
            }
        } else {
            exitAttributionTimer?.invalidate()
            exitAttributionTimer = nil
        }
    }

    /**
     * Re-pulls the destination->exit join and rebuilds the rows when it
     * moved. The readout is an rpc into the extension, so it runs off the
     * main thread; refreshes coalesce (at most one in flight)
     */
    private func refreshExitAttribution() {
        guard exitAttributionActive, !exitAttributionRefreshing, let device = self.device else {
            return
        }
        exitAttributionRefreshing = true
        Task { [weak self] in
            let exitsByIp = await Self.fetchExitsByIp(device)
            guard let self else {
                return
            }
            self.exitAttributionRefreshing = false
            guard self.device === device else {
                // the device changed mid-flight; the next refresh reads the new one
                return
            }
            if self.exitsByIp != exitsByIp {
                self.exitsByIp = exitsByIp
                self.updateBlockActions()
            }
        }
    }

    /**
     * destination ip -> short client ids of the exits currently carrying
     * flows to it. nonisolated so the rpc runs off the main actor
     */
    private nonisolated static func fetchExitsByIp(_ device: SdkDeviceRemote) async -> [String: Set<String>] {
        var exitsByIp: [String: Set<String>] = [:]
        if let destinationExits = device.getDestinationExits() {
            for i in 0..<destinationExits.len() {
                guard let destinationExit = destinationExits.get(i),
                      let idStr = destinationExit.clientId?.idStr else {
                    continue
                }
                exitsByIp[destinationExit.destinationIp, default: []].insert(String(idStr.prefix(8)))
            }
        }
        return exitsByIp
    }

    private func updateBlockActions() {
        guard let vc = blockActionViewController else {
            return
        }
        var items: [BlockActionItem] = []
        if let list = vc.getBlockActions() {
            items.reserveCapacity(list.len())
            for i in 0..<list.len() {
                guard let action = list.get(i) else {
                    continue
                }
                let unmatchedHosts = stringListToArray(action.hosts)
                let ips = stringListToArray(action.ips)
                let matchedIps = stringListToArray(action.matchedIps)
                // the live destination->exit attribution join (see
                // `refreshExitAttribution`)
                var exitIds = Set<String>()
                for ip in matchedIps + ips {
                    if let exits = exitsByIp[ip] {
                        exitIds.formUnion(exits)
                    }
                }
                items.append(
                    BlockActionItem(
                        id: action.blockActionId?.idStr ?? UUID().uuidString,
                        time: Date(timeIntervalSince1970: TimeInterval(action.time) / 1000.0),
                        hosts: unmatchedHosts,
                        ips: ips,
                        matchedHosts: stringListToArray(action.matchedHosts),
                        matchedIps: matchedIps,
                        hostBaseNames: collapseHosts(unmatchedHosts),
                        block: action.block,
                        local: action.local,
                        overrideId: action.overrideId?.idStr,
                        hasBlockOverride: action.blockOverride != nil,
                        hasRouteOverride: action.routeOverride != nil,
                        packetCount: action.packetCount,
                        byteCount: action.byteCount,
                        exitShortIds: exitIds.sorted()
                    )
                )
            }
        }
        // newest first; only publish when the list actually changed (the SDK
        // re-emits per routing decision, storming observers otherwise)
        let newActions = Array(items.reversed())
        if newActions != blockActions {
            blockActions = newActions
        }
    }

    private func updateBlockStats() {
        guard let vc = blockActionViewController else {
            return
        }
        let stats = vc.getBlockStats()
        let newAllowed = stats?.allowedCount ?? 0
        let newBlocked = stats?.blockedCount ?? 0
        if newAllowed != allowedCount {
            allowedCount = newAllowed
        }
        if newBlocked != blockedCount {
            blockedCount = newBlocked
        }
    }

    private func updateOverrides() {
        guard let device = self.device else {
            return
        }
        var overrides: [SdkBlockActionOverride] = []
        var items: [SplitRuleItem] = []
        if let list = device.getBlockActionOverrides() {
            for i in 0..<list.len() {
                guard let override = list.get(i), let overrideId = override.overrideId else {
                    continue
                }
                overrides.append(override)
                let ruleHosts = stringListToArray(override.hosts)
                let ruleHostNames = ruleHosts.filter { !isIpAddressValue($0) }
                let ruleIps = ruleHosts.filter { isIpAddressValue($0) }
                items.append(
                    SplitRuleItem(
                        id: overrideId.idStr,
                        hosts: ruleHosts,
                        hostBaseNames: collapseHosts(ruleHostNames),
                        ipValues: ruleIps,
                        // excluded when the route override is local, pinned
                        // when it carries a pin, else included
                        mode: SplitRuleMode.of(
                            local: override.routeOverride?.local ?? false,
                            pin: override.routeOverride?.pin ?? false
                        )
                    )
                )
            }
        }
        sdkOverrides = overrides
        if items != splitRules {
            splitRules = items
        }
    }

    /**
     * the split rule matching a block action's applied override, if it still exists
     */
    func splitRule(overrideId: String?) -> SplitRuleItem? {
        guard let overrideId = overrideId else {
            return nil
        }
        return splitRules.first { $0.id == overrideId }
    }

    /**
     * creates a split rule applying `mode` to the selected host values;
     * see `SplitRuleMode`
     */
    func createRule(hosts: [String], mode: SplitRuleMode) {
        guard let device = self.device, !hosts.isEmpty else {
            return
        }
        let override = SdkBlockActionOverride()
        override.overrideId = SdkNewId()
        override.hosts = arrayToStringList(hosts)
        override.routeOverride = mode.toSdkRouteOverride()
        device.add(override)
        updateOverrides()
    }

    /**
     * replaces the host values and mode of an existing split rule
     */
    func updateRule(id: String, hosts: [String], mode: SplitRuleMode) {
        guard let device = self.device else {
            return
        }
        guard let override = sdkOverrides.first(where: { $0.overrideId?.idStr == id }) else {
            return
        }
        if hosts.isEmpty {
            removeRule(id: id)
            return
        }
        override.hosts = arrayToStringList(hosts)
        override.routeOverride = mode.toSdkRouteOverride()
        let list = SdkBlockActionOverrideList()
        for sdkOverride in sdkOverrides {
            list?.add(sdkOverride)
        }
        device.setBlockActionOverrides(list)
        updateOverrides()
    }

    func removeRule(id: String) {
        guard let device = self.device else {
            return
        }
        guard let override = sdkOverrides.first(where: { $0.overrideId?.idStr == id }) else {
            return
        }
        device.removeBlockActionOverride(override.overrideId)
        updateOverrides()
    }

    private func stringListToArray(_ list: SdkStringList?) -> [String] {
        guard let list = list else {
            return []
        }
        var values: [String] = []
        values.reserveCapacity(list.len())
        for i in 0..<list.len() {
            values.append(list.get(i))
        }
        return values
    }

    private func arrayToStringList(_ values: [String]) -> SdkStringList? {
        let list = SdkStringList()
        for value in values {
            list?.add(value)
        }
        return list
    }

    /**
     * collapse host names to base names through the shared SDK logic
     * (SdkCollapseHostNames), so every platform collapses identically
     */
    private func collapseHosts(_ hosts: [String]) -> [String] {
        if hosts.isEmpty {
            return []
        }
        return stringListToArray(SdkCollapseHostNamesList(arrayToStringList(hosts)))
    }
}
