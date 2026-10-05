//
//  SplitTunnelAppRules.swift
//  URnetwork
//
//  App split rules are stored with the site split rules: an sdk
//  BlockActionOverride whose AppIds name the apps (signing identifiers on
//  macOS, package names on android) and whose RouteOverride says where they
//  go. The packet path ignores them (sdk connectBlockActionOverrides skips
//  overrides without hosts); the platform enforces them -- android with
//  per-app VpnService routing, macOS with the split tunnel system extension.
//
//  macOS takes apps OUT of the tunnel only (route locally). Which apps that
//  is follows the sdk's own derivation (DeviceLocal.GetLocalOverrideAppIds,
//  whose "included" set is the local-routed apps) so a rule means the same
//  thing on every platform: a pin that stays in the tunnel is placement, not
//  membership, and is skipped; an app named by several rules takes the first
//  one that counts.
//
//  Pure Foundation, so the tests drive it on the iOS simulator.
//

import Foundation

/// An app split rule, the app-facing projection of its sdk override.
struct SplitTunnelAppRule: Identifiable, Equatable {
    /// the override id
    let id: String
    let appIds: [String]
    let local: Bool
    let pin: Bool
}

enum SplitTunnelAppRules {

    /// The signing identifiers the rules route locally, in rule order.
    static func excludedApps(_ rules: [SplitTunnelAppRule]) -> [String] {
        var seen = Set<String>()
        var excluded: [String] = []
        for rule in rules {
            if rule.pin && !rule.local {
                // a pin holds the app to one exit INSIDE the tunnel
                continue
            }
            for appId in rule.appIds {
                guard seen.insert(appId).inserted else {
                    continue
                }
                if rule.local {
                    excluded.append(appId)
                }
            }
        }
        return excluded
    }

    /// Whether `identifier` is one of the apps the rules route locally,
    /// ignoring case (the matcher does).
    static func isExcluded(_ identifier: String, in rules: [SplitTunnelAppRule]) -> Bool {
        let wanted = identifier.lowercased()
        return excludedApps(rules).contains { $0.lowercased() == wanted }
    }
}
