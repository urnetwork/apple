//
//  SplitTunnelAppRulesTests.swift
//  networkTests
//
//  The macOS excluded apps are stored with the site split rules, as sdk
//  BlockActionOverrides that carry app ids (the way android stores its app
//  split rules), and the apps the extension takes out of the tunnel are the
//  ones the sdk itself derives as routed locally. These pin that derivation
//  (network/Shared/SplitTunnel/SplitTunnelAppRules.swift), the projection
//  of an override into an app rule (BlockActionsStore.appRule), and that
//  the app ids survive the app's own durable mirror of the rules.
//

import Testing
import Foundation
import URnetworkSdk
@testable import URnetwork

struct SplitTunnelAppRulesTests {

    private func rule(_ id: String, _ appIds: [String], local: Bool, pin: Bool = false) -> SplitTunnelAppRule {
        SplitTunnelAppRule(id: id, appIds: appIds, local: local, pin: pin)
    }

    // MARK: derivation

    @Test func routedLocallyAppsAreExcludedInRuleOrder() {
        let rules = [
            rule("a", ["com.example.Bank"], local: true),
            rule("b", ["example.meet.xos", "com.example.Game"], local: true),
        ]
        #expect(SplitTunnelAppRules.excludedApps(rules) == ["com.example.Bank", "example.meet.xos", "com.example.Game"])
    }

    @Test func appsRoutedThroughTheTunnelAreNotExcluded() {
        // android's allowlist rules; macOS only takes apps out
        #expect(SplitTunnelAppRules.excludedApps([rule("a", ["com.example.Bank"], local: false)]).isEmpty)
    }

    @Test func aPinThatStaysInTheTunnelIsPlacementNotMembership() {
        let rules = [
            rule("pin", ["com.example.Bank"], local: false, pin: true),
            rule("local", ["com.example.Bank"], local: true),
        ]
        // the pin is skipped, so the later local rule still counts
        #expect(SplitTunnelAppRules.excludedApps(rules) == ["com.example.Bank"])
        // a local pin routes locally
        #expect(SplitTunnelAppRules.excludedApps([rule("p", ["com.example.Game"], local: true, pin: true)]) == ["com.example.Game"])
    }

    @Test func anAppNamedByTwoRulesTakesTheFirstThatCounts() {
        // the same first-wins rule as sdk DeviceLocal.GetLocalOverrideAppIds
        let remoteFirst = [
            rule("remote", ["com.example.Bank"], local: false),
            rule("local", ["com.example.Bank"], local: true),
        ]
        #expect(SplitTunnelAppRules.excludedApps(remoteFirst).isEmpty)
        let localFirst = [
            rule("local", ["com.example.Bank"], local: true),
            rule("remote", ["com.example.Bank"], local: false),
        ]
        #expect(SplitTunnelAppRules.excludedApps(localFirst) == ["com.example.Bank"])
    }

    @Test func isExcludedIgnoresCase() {
        let rules = [rule("a", ["com.example.Bank"], local: true)]
        #expect(SplitTunnelAppRules.isExcluded("COM.example.bank", in: rules))
        #expect(!SplitTunnelAppRules.isExcluded("com.example.Other", in: rules))
        #expect(!SplitTunnelAppRules.isExcluded("com.example.Bank", in: [rule("a", ["com.example.Bank"], local: false)]))
    }

    // MARK: sdk overrides

    private func override(hosts: [String]? = nil, appIds: [String]? = nil, local: Bool, pin: Bool = false) -> SdkBlockActionOverride {
        let override = SdkBlockActionOverride()
        override.overrideId = SdkNewId()
        if let hosts {
            let list = SdkStringList()
            for host in hosts {
                list?.add(host)
            }
            override.hosts = list
        }
        if let appIds {
            let list = SdkStringList()
            for appId in appIds {
                list?.add(appId)
            }
            override.appIds = list
        }
        let routeOverride = SdkRouteOverride()
        routeOverride.local = local
        routeOverride.pin = pin
        override.routeOverride = routeOverride
        return override
    }

    @Test func anOverrideWithAppIdsIsAnAppRule() throws {
        let sdkOverride = override(appIds: ["com.example.Bank"], local: true)
        let appRule = try #require(BlockActionsStore.appRule(sdkOverride))
        #expect(appRule.id == sdkOverride.overrideId?.idStr)
        #expect(appRule.appIds == ["com.example.Bank"])
        #expect(appRule.local)
        #expect(!appRule.pin)
    }

    @Test func aSiteRuleIsNotAnAppRule() {
        #expect(BlockActionsStore.appRule(override(hosts: ["example.com"], local: true)) == nil)
        #expect(BlockActionsStore.appRule(override(hosts: ["example.com"], appIds: [], local: true)) == nil)
    }

    /// The app's mirror is what renders the rules with the tunnel down and
    /// seeds the next device; an app rule must come back from it whole.
    @Test func appRulesSurviveTheMirror() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitTunnelAppRulesTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let asyncLocalState = try #require(SdkAsyncLocalState(home.path()))
        defer { asyncLocalState.close() }
        let localState = try #require(asyncLocalState.getLocalState())

        let list = try #require(SdkBlockActionOverrideList())
        list.add(override(hosts: ["example.com"], local: true))
        list.add(override(appIds: ["com.example.Bank", "example.meet.xos"], local: true))
        try localState.setBlockActionOverrides(list)

        let read = try #require(localState.getBlockActionOverrides())
        #expect(read.len() == 2)
        var appRules: [SplitTunnelAppRule] = []
        for i in 0..<read.len() {
            if let sdkOverride = read.get(i), let appRule = BlockActionsStore.appRule(sdkOverride) {
                appRules.append(appRule)
            }
        }
        #expect(appRules.count == 1)
        #expect(SplitTunnelAppRules.excludedApps(appRules) == ["com.example.Bank", "example.meet.xos"])
    }
}
