//
//  SplitTunnelProxyPlanTests.swift
//  networkTests
//
//  SplitTunnelProxyController drives the split tunnel extension and its
//  transparent proxy configuration through one loop: the plan names the
//  next step from what the app wants and what the system holds. These pin
//  the plan (network/Shared/SplitTunnel/SplitTunnelProxyPlan.swift): when
//  the extension is activated, when the configuration is saved or removed,
//  that the proxy runs only while the user wants the VPN connected, and what
//  the Apps section says in each state.
//

import Testing
import Foundation
@testable import URnetwork

struct SplitTunnelProxyPlanTests {

    private let bank = ["com.example.Bank"]

    private func installed(_ apps: [String]?, enabled: Bool = true, running: Bool = false) -> SplitTunnelProxyObserved {
        SplitTunnelProxyObserved(
            configuration: apps.map { SplitTunnelProxyConfiguration(excludedApps: $0) },
            isInstalled: true,
            isEnabled: enabled,
            isRunning: running
        )
    }

    private func inputs(
        wanted: [String]?,
        connect: Bool = false,
        extensionState: SystemExtensionActivationState = .activated(willCompleteAfterReboot: false),
        observed: SplitTunnelProxyObserved?
    ) -> SplitTunnelProxyInputs {
        SplitTunnelProxyInputs(
            wantedApps: wanted,
            connectEnabled: connect,
            extensionState: extensionState,
            observed: observed
        )
    }

    private func next(_ inputs: SplitTunnelProxyInputs) -> SplitTunnelProxyStep {
        SplitTunnelProxyPlan.nextStep(inputs)
    }

    // MARK: steps

    @Test func theSystemsConfigurationIsLoadedFirst() {
        #expect(next(inputs(wanted: bank, connect: true, observed: nil)) == .load)
        #expect(next(inputs(wanted: nil, observed: nil)) == .load)
    }

    @Test func nothingHappensUntilAnAppIsExcluded() {
        // no list yet and nothing installed: not even the extension
        #expect(next(inputs(wanted: nil, connect: true, extensionState: .idle, observed: .absent)) == .none)
        #expect(next(inputs(wanted: [], connect: true, extensionState: .idle, observed: .absent)) == .none)
    }

    @Test func theFirstExcludedAppActivatesTheExtension() {
        #expect(next(inputs(wanted: bank, extensionState: .idle, observed: .absent)) == .activateExtension)
    }

    @Test func anInstalledConfigurationReactivatesTheExtensionAtLaunch() {
        // how an updated app replaces the extension it embeds
        #expect(next(inputs(wanted: nil, extensionState: .idle, observed: installed(bank))) == .activateExtension)
    }

    @Test func aPendingOrFailedActivationWaits() {
        for state: SystemExtensionActivationState in [
            .requesting,
            .needsApproval,
            .notInApplications(.elsewhere),
            .failed(.missingEntitlement),
        ] {
            #expect(next(inputs(wanted: bank, connect: true, extensionState: state, observed: .absent)) == .none, "\(state)")
        }
    }

    @Test func theConfigurationIsSavedWithTheWantedList() {
        let wanted = SplitTunnelProxyConfiguration(excludedApps: bank)
        #expect(next(inputs(wanted: bank, observed: .absent)) == .save(wanted))
        #expect(next(inputs(wanted: bank, observed: installed(["com.example.Other"]))) == .save(wanted))
        // a configuration this build cannot read is replaced
        #expect(next(inputs(wanted: bank, observed: installed(nil))) == .save(wanted))
        // and one turned off in System Settings is turned back on
        #expect(next(inputs(wanted: bank, observed: installed(bank, enabled: false))) == .save(wanted))
    }

    @Test func anEquivalentListIsNotSavedAgain() {
        // rule order is not list order: no rewrite of the system's preferences
        let observed = installed(["b.example.app", "a.example.app"])
        #expect(next(inputs(wanted: ["a.example.app", "b.example.app"], observed: observed)) == .none)
        #expect(next(inputs(wanted: ["b.example.app", "a.example.app", "b.example.app"], observed: observed)) == .none)
    }

    @Test func theProxyRunsOnlyWhileTheVpnIsWanted() {
        #expect(next(inputs(wanted: bank, connect: true, observed: installed(bank))) == .start)
        #expect(next(inputs(wanted: bank, connect: true, observed: installed(bank, running: true))) == .none)
        #expect(next(inputs(wanted: bank, connect: false, observed: installed(bank, running: true))) == .stop)
        #expect(next(inputs(wanted: bank, connect: false, observed: installed(bank))) == .none)
    }

    @Test func withNoListTheInstalledConfigurationStillFollowsTheVpn() {
        #expect(next(inputs(wanted: nil, connect: true, observed: installed(bank))) == .start)
        #expect(next(inputs(wanted: nil, connect: false, observed: installed(bank, running: true))) == .stop)
        // and is never saved over: there is nothing to save
        #expect(next(inputs(wanted: nil, connect: false, observed: installed(["com.example.Other"]))) == .none)
    }

    @Test func theLastAppRemovedRemovesTheConfiguration() {
        #expect(next(inputs(wanted: [], connect: true, observed: installed(bank, running: true))) == .remove)
        // whatever the extension's state: nothing to activate for a removal
        #expect(next(inputs(wanted: [], extensionState: .idle, observed: installed(bank))) == .remove)
        // a list of nothing usable is no list
        #expect(next(inputs(wanted: ["not an identifier"], observed: installed(bank))) == .remove)
    }

    @Test func aDisabledConfigurationIsNotStartedWithoutAList() {
        #expect(next(inputs(wanted: nil, connect: true, observed: installed(bank, enabled: false))) == .none)
    }

    // MARK: status

    private func status(_ inputs: SplitTunnelProxyInputs, failed: Bool = false) -> SplitTunnelProxyStatus {
        SplitTunnelProxyPlan.status(inputs, failed: failed)
    }

    @Test func theStatusIsOffWithNothingExcluded() {
        #expect(status(inputs(wanted: [], observed: .absent)) == .off)
        #expect(status(inputs(wanted: nil, observed: .absent)) == .off)
        #expect(status(inputs(wanted: [], extensionState: .failed(.missingEntitlement), observed: .absent), failed: true) == .off)
    }

    @Test func theStatusAsksForTheApproval() {
        #expect(status(inputs(wanted: bank, extensionState: .needsApproval, observed: .absent)) == .needsApproval)
    }

    @Test func theStatusReportsAFailure() {
        #expect(status(inputs(wanted: bank, extensionState: .failed(.forbiddenBySystemPolicy), observed: .absent)) == .failed)
        #expect(status(inputs(wanted: bank, extensionState: .notInApplications(.diskImage), observed: .absent)) == .failed)
        // the controller's latch: a save or start failed
        #expect(status(inputs(wanted: bank, observed: .absent), failed: true) == .failed)
    }

    @Test func theStatusFollowsTheProxy() {
        #expect(status(inputs(wanted: bank, extensionState: .requesting, observed: .absent)) == .pending)
        #expect(status(inputs(wanted: bank, observed: nil)) == .pending)
        #expect(status(inputs(wanted: bank, observed: .absent)) == .pending)
        #expect(status(inputs(wanted: bank, connect: false, observed: installed(bank))) == .ready)
        #expect(status(inputs(wanted: bank, connect: true, observed: installed(bank))) == .pending)
        #expect(status(inputs(wanted: bank, connect: true, observed: installed(bank, running: true))) == .active)
        #expect(status(inputs(wanted: nil, connect: true, observed: installed(bank, running: true))) == .active)
    }
}
