//
//  NetworkSpaceSelectionTests.swift
//  networkTests
//
//  Pins the one boolean that decides which network space the app binds to on
//  launch.
//
//  This is the truth table iOS got wrong. `initializeNetworkSpace()` used to
//  bind `getNetworkSpace(<bundled key>)` unconditionally and never read the
//  space the SDK had persisted, which is the same as answering "activate the
//  bundled space" to every row below. For a user who had selected a different
//  network space that reverted the API host to the bundled space's
//  "bringyour.com" migration host AND sent the startup jwt read to the wrong
//  per-host state directory -- reported as being logged out and reset to the
//  default server on every restart.
//
//  Android has always had it right, so it is the reference. MainApplication.kt:
//      if (!bundleNetworkSpaceExists || networkSpaceManager?.activeNetworkSpace == null)
//
//  The bug survived because the condition was inlined and unreachable from a
//  test. Extracting it is the point; these cases are the contract.
//

import Testing
@testable import URnetwork

struct NetworkSpaceSelectionTests {

    @Test func firstInstallActivatesTheBundledSpace() {
        // Nothing persisted at all -- the bundled space was just created by
        // updateNetworkSpace and there is no user choice to honour, so it has to
        // become active or the app comes up bound to nothing.
        #expect(
            NetworkSpaceSelection.shouldActivateBundled(
                bundledSpaceExisted: false,
                hasActiveSpace: false
            )
        )
    }

    @Test func normalLaunchKeepsTheUsersSelectedSpace() {
        // The regression case. The bundled space already exists and something is
        // already active -- on an install pointed at a self-hosted server that
        // active space holds the credentials and the API host. Re-activating the
        // bundled space here is exactly what logged the user out and reverted
        // them to the official host.
        #expect(
            NetworkSpaceSelection.shouldActivateBundled(
                bundledSpaceExisted: true,
                hasActiveSpace: true
            ) == false
        )
    }

    @Test func bundledSpaceWithNoActiveSpaceActivates() {
        // Spaces on disk but no active pointer: an interrupted first run, or state
        // written by a build predating the active-space record. There is no choice
        // to preserve, so fall back to the bundled space rather than to nothing.
        #expect(
            NetworkSpaceSelection.shouldActivateBundled(
                bundledSpaceExisted: true,
                hasActiveSpace: false
            )
        )
    }

    @Test func newlyBundledSpaceActivatesEvenOverAnActiveSpace() {
        // Migration to a newer bundle: the new bundled key did not exist before
        // this launch. Android takes this branch too (`!bundleNetworkSpaceExists`
        // is checked first, before the active-space test), which is what its
        // comment means by "important when migrating from an older bundle".
        #expect(
            NetworkSpaceSelection.shouldActivateBundled(
                bundledSpaceExisted: false,
                hasActiveSpace: true
            )
        )
    }

    @Test func activationDependsOnlyOnTheTwoInputs() {
        // The whole decision, spelled out, so a future edit that reintroduces an
        // unconditional activation fails here rather than in a user's session.
        let table: [(bundledSpaceExisted: Bool, hasActiveSpace: Bool, activate: Bool)] = [
            (false, false, true),
            (false, true, true),
            (true, false, true),
            (true, true, false),
        ]

        for row in table {
            #expect(
                NetworkSpaceSelection.shouldActivateBundled(
                    bundledSpaceExisted: row.bundledSpaceExisted,
                    hasActiveSpace: row.hasActiveSpace
                ) == row.activate,
                "bundledSpaceExisted=\(row.bundledSpaceExisted) hasActiveSpace=\(row.hasActiveSpace)"
            )
        }
    }
}
