//
//  SplitRulePreset.swift
//  URnetwork
//
//  Opt-in starting points for a split rule: the address ranges a service
//  publishes itself for sending its traffic around a VPN.
//
//  Apple allows per-app VPN (NEAppRule) only on devices an organization
//  manages (MDM), so the app cannot exclude an app on its own. A preset is
//  the nearest thing: a route-locally rule filled in with the ranges the
//  service documents for exactly this use. The bar for adding one is that the
//  service publishes the values for use outside a VPN, at the source kept next
//  to them. Nothing here is guessed from traffic, and there is no banking or
//  streaming preset because none of those services publish theirs.
//
//  The ranges change rarely, but they do change: check them against the
//  sources when touching this file (last checked 2026-10-04). Kept free of
//  SwiftUI and of the SDK so it can be tested directly.
//

import Foundation

/// One preset: the ranges a service publishes for use outside a VPN, and
/// where it publishes them.
struct SplitRulePreset: Identifiable {
    let id: String
    let name: String.LocalizationValue
    /// the rule's values, in the form the matcher stores them
    let hosts: [String]
    /// where the service publishes them
    let source: URL

    static let microsoftTeams = SplitRulePreset(
        id: "microsoft-teams",
        name: "Microsoft Teams calls",
        // Microsoft 365 endpoint set 11 ("Optimize"): Teams media, which
        // Microsoft says to route outside a VPN
        hosts: [
            "52.112.0.0/14",
            "52.122.0.0/15",
            "2603:1063::/38",
        ],
        source: URL(string: "https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-vpn-implement-split-tunnel")!
    )

    static let googleMeet = SplitRulePreset(
        id: "google-meet",
        name: "Google Meet calls",
        // the Meet media ranges (Workspace, then consumer), which Google says
        // to route outside a VPN by prefix
        hosts: [
            "74.125.250.0/24",
            "74.125.247.128/32",
            "2001:4860:4864:5::/64",
            "2001:4860:4864:4:8000::/128",
            "142.250.82.0/24",
            "2001:4860:4864:6::/64",
        ],
        source: URL(string: "https://knowledge.workspace.google.com/admin/meet/prepare-your-network-for-meet-meetings-and-live-streams")!
    )

    static let all: [SplitRulePreset] = [microsoftTeams, googleMeet]

    /// True when one rule already holds every value of the preset, so
    /// starting from it again would only add a second copy of that rule.
    func isApplied(in ruleHosts: [[String]]) -> Bool {
        ruleHosts.contains { hosts in
            self.hosts.allSatisfy(hosts.contains)
        }
    }
}
