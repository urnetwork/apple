import Foundation
import XCTest

final class TunnelRecoveryTests: XCTestCase {
    func testColdExtensionRestoresSavedDestinationWithoutRpc() throws {
        var events: [String] = []
        let plan = try restoreTunnelDestination(
            intent: .none, savedLocationHasCurrentOwner: true,
            loadSaved: { events.append("saved"); return "private-peer" },
            loadDefault: { events.append("default"); return "default" },
            bestAvailable: { XCTFail("saved destination must win"); return "best" },
            isCurrent: { true },
            apply: { events.append("consumer:" + ($0.location ?? "nil")) }
        )
        XCTAssertEqual(plan.stage, .saved)
        XCTAssertEqual(events, ["saved", "consumer:private-peer"])
    }

    func testCurrentAppConnectSelectsLoadedDefaultForCheckedMutation() throws {
        var events: [String] = []
        let plan = try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil }, loadDefault: { "selected-peer" },
            bestAvailable: { XCTFail("default must win"); return "best" },
            isCurrent: { true },
            apply: { events.append("checked-mutation:" + ($0.location ?? "nil")) }
        )
        XCTAssertEqual(plan.stage, .sharedDefault)
        XCTAssertEqual(events, ["checked-mutation:selected-peer"])
    }

    func testCurrentConnectWithGenuinelyAbsentLoadedLocationsSelectsBestAvailable() throws {
        var saved: String?
        let plan = try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil }, loadDefault: { nil }, bestAvailable: { "best" },
            isCurrent: { true }, apply: { saved = $0.location }
        )
        XCTAssertEqual(plan.location, "best")
        XCTAssertEqual(plan.stage, .sharedBestAvailable)
        XCTAssertEqual(saved, "best")
    }

    func testExplicitDisconnectOverridesSurvivingSavedDestination() throws {
        var saved: String? = "old-peer"
        let plan = try restoreTunnelDestination(
            intent: .disconnect, savedLocationHasCurrentOwner: true,
            loadSaved: { saved }, loadDefault: { "default-peer" },
            bestAvailable: { XCTFail("disconnect cannot select a provider"); return "best" },
            isCurrent: { true }, apply: { saved = $0.location }
        )
        XCTAssertEqual(plan.stage, .explicitDisconnect)
        XCTAssertNil(saved)
    }

    func testUnknownIntentCannotAdoptUnownedSavedOrDefaultLocation() throws {
        let plan = try restoreTunnelDestination(
            intent: .none, savedLocationHasCurrentOwner: false,
            loadSaved: { "other-owner-private-peer" }, loadDefault: { "other-owner-default" },
            bestAvailable: { XCTFail("unknown intent must stay local"); return "best" },
            isCurrent: { true }, apply: { XCTAssertNil($0.location); XCTAssertEqual($0.stage, .localOnly) }
        )
        XCTAssertEqual(plan.stage, .localOnly)
    }

    func testKnownNewOwnerConnectNeverReusesOldOwnerPrivateDefault() throws {
        let plan = try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: false,
            loadSaved: { "old-private-peer" }, loadDefault: { "old-private-default" },
            bestAvailable: { "explicit-current-owner-best" },
            isCurrent: { true }, apply: { XCTAssertEqual($0.location, "explicit-current-owner-best") }
        )
        XCTAssertEqual(plan.stage, .sharedBestAvailable)
    }

    func testFailedSavedReadCannotFallBackOrConstructConsumer() {
        var events: [String] = []
        XCTAssertThrowsError(try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { () throws -> String? in throw FixtureError.read },
            loadDefault: { events.append("default"); return "default" },
            bestAvailable: { events.append("best"); return "best" },
            isCurrent: { true }, apply: { _ in events.append("checked-mutation") }
        ))
        XCTAssertEqual(events, [])
    }

    func testFailedDefaultReadCannotBecomeBestAvailable() {
        var events: [String] = []
        XCTAssertThrowsError(try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil as String? }, loadDefault: { throw FixtureError.read },
            bestAvailable: { events.append("best"); return "best" },
            isCurrent: { true }, apply: { _ in events.append("checked-mutation") }
        ))
        XCTAssertEqual(events, [])
    }

    func testCheckedMutationFailureIsReturnedWithoutSuccessBreadcrumb() {
        var mutationAttempted = false
        var reports: [String] = []
        XCTAssertThrowsError(try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil }, loadDefault: { "selected" }, bestAvailable: { "best" },
            isCurrent: { true },
            apply: { _ in mutationAttempted = true; throw FixtureError.write },
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertTrue(mutationAttempted)
        XCTAssertFalse(reports.contains("consumer=accepted"))
    }

    func testDestinationGenerationChangeDuringReadRejectsLateAdoption() {
        var generation = 1
        let ticket = generation
        var mutated = false
        XCTAssertThrowsError(try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil }, loadDefault: { generation += 1; return "old-choice" },
            bestAvailable: { "best" }, isCurrent: { ticket == generation },
            apply: { _ in mutated = true }
        ))
        XCTAssertFalse(mutated)
    }

    func testNativeOwnerRetiredBeforeCheckedMutationCannotConstructConsumer() {
        var constructed = false
        XCTAssertThrowsError(try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil }, loadDefault: { "selected" }, bestAvailable: { "best" },
            isCurrent: { false }, apply: { _ in constructed = true }
        ))
        XCTAssertFalse(constructed)
    }

    func testSameOwnerTokenRotationRecapturesObservationWithoutFallback() throws {
        var attempts = 0
        var superseded = 0
        let value = try withCurrentTunnelAuthObservation(
            isCurrent: { true }, superseded: { superseded += 1 }
        ) {
            attempts += 1
            if attempts == 1 { throw supersededError() }
            return "same-owner-saved-peer"
        }
        XCTAssertEqual(value, "same-owner-saved-peer")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(superseded, 1)
    }

    func testUnsettledAuthObservationHasFiniteImmediateBudget() {
        var attempts = 0
        XCTAssertThrowsError(try withCurrentTunnelAuthObservation(
            isCurrent: { true }, superseded: {}
        ) { () throws -> String in
            attempts += 1
            throw supersededError()
        })
        XCTAssertEqual(attempts, 3)
    }

    func testReadFailureDoesNotEnterSupersessionRecapture() {
        var attempts = 0
        XCTAssertThrowsError(try withCurrentTunnelAuthObservation(
            isCurrent: { true }, superseded: { XCTFail("not a supersession") }
        ) { () throws -> String in
            attempts += 1
            throw FixtureError.read
        })
        XCTAssertEqual(attempts, 1)
    }

    func testRetiredOwnerCannotUseSameOwnerObservationRecapture() {
        var current = true
        var attempts = 0
        XCTAssertThrowsError(try withCurrentTunnelAuthObservation(
            isCurrent: { current }, superseded: { XCTFail("owner was retired") }
        ) { () throws -> String in
            attempts += 1
            current = false
            throw supersededError()
        })
        XCTAssertEqual(attempts, 1)
    }

    func testSupersededConditionalResetPreventsSelectionAndConstruction() {
        var events: [String] = []
        XCTAssertThrowsError(try prepareTunnelLocalAuthState(
            configuredInstanceId: "new-instance",
            readAuthIdentity: { TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "old-instance") },
            clearStaleState: { try requireTunnelResetCompleted(false) },
            selectClientJwt: { events.append("select"); return "unused" },
            startSession: { _ in events.append("construct") }
        ))
        XCTAssertEqual(events, [])
    }

    func testKnownClientOwnerConflictWithinSameInstanceRequiresReset() throws {
        var events: [String] = []
        let _: String = try prepareTunnelLocalAuthState(
            configuredInstanceId: "same-instance",
            readAuthIdentity: {
                TunnelLocalAuthIdentitySnapshot(
                    isEmpty: false, instanceId: "same-instance", knownClientOwnerConflict: true
                )
            },
            clearStaleState: { events.append("reset") },
            selectClientJwt: { events.append("select"); return "accepted-client" },
            startSession: { events.append("construct"); return $0 }
        )
        XCTAssertEqual(events, ["reset", "select", "construct"])
    }

    func testInitialFalseToFalseReadinessStillReconcilesLocalSettings() {
        var owner = TunnelReadinessOwner()
        let state = tunnelReadiness(connectIntended: false, consumerPresent: false, providerCount: 0)
        XCTAssertEqual(state, .local)
        XCTAssertNotNil(owner.begin(.init(readiness: state, dnsOwned: false)))
    }

    func testInitialIntendedConnectionWithNoConsumerIsEstablishing() {
        XCTAssertEqual(tunnelReadiness(connectIntended: true, consumerPresent: false, providerCount: 0), .establishing)
    }

    func testSameReadinessStillReconcilesWhenDnsOwnershipChanges() {
        var owner = TunnelReadinessOwner()
        XCTAssertNotNil(owner.begin(.init(readiness: .establishing, dnsOwned: false)))
        XCTAssertNotNil(owner.begin(.init(readiness: .establishing, dnsOwned: true)))
        XCTAssertNil(owner.begin(.init(readiness: .establishing, dnsOwned: true)))
    }

    func testSettingsFailureAllowsSameLevelSuccessWithoutTransportAction() throws {
        var owner = TunnelReadinessOwner()
        let state = TunnelReadinessOwner.State(readiness: .connected, dnsOwned: true)
        let failed = try XCTUnwrap(owner.begin(state))
        XCTAssertEqual(owner.complete(failed, succeeded: false), .failed(retry: true))
        let retry = try XCTUnwrap(owner.begin(state))
        XCTAssertEqual(owner.complete(retry, succeeded: true), .applied)
        XCTAssertNil(owner.begin(state))
    }

    func testOnlyAnAppliedLevelWithNothingInFlightCanReassert() throws {
        let owner = TunnelReadinessOwner()
        let state = TunnelReadinessOwner.State(readiness: .connected, dnsOwned: true)
        XCTAssertFalse(owner.isApplied(state))
        let ticket = try XCTUnwrap(owner.begin(state))
        XCTAssertFalse(owner.isApplied(state))
        XCTAssertEqual(owner.complete(ticket, succeeded: true), .applied)
        XCTAssertNil(owner.begin(state))
        XCTAssertTrue(owner.isApplied(state))
        XCTAssertFalse(owner.isApplied(.init(readiness: .establishing, dnsOwned: true)))
    }

    func testSettingsOnlyRetryDoesNotRestoreOrResetHealthyConsumer() throws {
        var effects: [String] = []
        XCTAssertTrue(try performTunnelRecovery(
            changeTransport: false, isCurrent: { true },
            restoreDestination: { effects.append("restore") }, networkChanged: { effects.append("transport") },
            reconcileReadiness: { effects.append("settings") }
        ))
        XCTAssertEqual(effects, ["settings"])
    }

    func testCanceledSettingsRetryDoesNothingEvenWithSameDevice() throws {
        var effects: [String] = []
        let queuedGeneration = 1
        let generationAfterSleep = 2
        XCTAssertFalse(try performTunnelRecovery(
            changeTransport: false, isCurrent: { queuedGeneration == generationAfterSleep },
            restoreDestination: { effects.append("restore") }, networkChanged: { effects.append("transport") },
            reconcileReadiness: { effects.append("settings") }
        ))
        XCTAssertEqual(effects, [])
    }

    func testPathRecoveryReconcilesReadinessEvenWithUnchangedDestination() throws {
        var effects: [String] = []
        XCTAssertTrue(try performTunnelRecovery(
            changeTransport: true, isCurrent: { true },
            restoreDestination: { effects.append("unchanged") }, networkChanged: { effects.append("transport") },
            reconcileReadiness: { effects.append("settings") }
        ))
        XCTAssertEqual(effects, ["unchanged", "transport", "settings"])
    }

    func testInitialPathQualityIsOnlyABaseline() {
        var tracker = TunnelNetworkQualityTracker()
        let quality = TunnelNetworkQuality(
            expensive: false, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: 4
        )

        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: quality))
    }

    func testQualityChangeOnStablePathRequestsRemeasurement() {
        var tracker = TunnelNetworkQualityTracker()
        let strong = TunnelNetworkQuality(
            expensive: false, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: 4
        )
        let constrained = TunnelNetworkQuality(
            expensive: false, constrained: true, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: 2
        )
        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: strong))

        XCTAssertTrue(tracker.observe(pathSignature: "wifi-a", quality: constrained))
        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: constrained))
    }

    func testPhysicalPathChangeEstablishesNewQualityBaseline() {
        var tracker = TunnelNetworkQualityTracker()
        let wifi = TunnelNetworkQuality(
            expensive: false, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: 4
        )
        let cellular = TunnelNetworkQuality(
            expensive: true, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: false, cellularTypes: ["5g"], wifiSignalLevel: nil
        )
        _ = tracker.observe(pathSignature: "wifi-a", quality: wifi)

        XCTAssertFalse(tracker.observe(pathSignature: "cell-a", quality: cellular))
    }

    private let wifiA = TunnelPhysicalPathSignature(
        interfaces: ["en0:wifi"], gateways: ["192.168.1.1"], addresses: ["192.168.1.20"]
    )
    // another network on the same interface, behind the same gateway address
    private let wifiB = TunnelPhysicalPathSignature(
        interfaces: ["en0:wifi"], gateways: ["192.168.1.1"], addresses: ["192.168.1.57"]
    )
    private let cellA = TunnelPhysicalPathSignature(
        interfaces: ["pdp_ip0:cellular"], gateways: [], addresses: ["10.20.30.40"]
    )

    @discardableResult
    private func settle(
        _ transition: inout TunnelPhysicalPathTransition,
        _ signature: TunnelPhysicalPathSignature,
        at: TimeInterval
    ) -> TunnelPhysicalPathTransition.Outcome? {
        guard let generation = transition.observeUsable(signature: signature) else { return nil }
        return transition.settle(generation, signature: signature, at: at)
    }

    func testFirstUsablePathIsOnlyABaseline() throws {
        var transition = TunnelPhysicalPathTransition()
        let generation = try XCTUnwrap(transition.observeUsable(signature: wifiA))
        XCTAssertEqual(transition.settle(generation, signature: wifiA, at: 0), .baseline)
    }

    func testPathChangeSettlesIntoOneRecovery() throws {
        var transition = TunnelPhysicalPathTransition()
        settle(&transition, wifiA, at: 0)
        let changed = try XCTUnwrap(transition.observeUsable(signature: cellA))
        XCTAssertEqual(transition.settle(changed, signature: cellA, at: 1), .changed(restored: false))
        XCTAssertEqual(transition.lastCause, .interfaces)
        let again = try XCTUnwrap(transition.observeUsable(signature: cellA))
        XCTAssertEqual(transition.settle(again, signature: cellA, at: 2), .unchanged)
    }

    func testFirstUsablePathAfterStartingOfflineRecovers() throws {
        var transition = TunnelPhysicalPathTransition()
        _ = transition.observeUnavailable()
        let generation = try XCTUnwrap(transition.observeUsable(signature: cellA))
        XCTAssertEqual(transition.settle(generation, signature: cellA, at: 0), .changed(restored: true))
    }

    func testSamePathAfterAnUnavailableEdgeRecovers() throws {
        var transition = TunnelPhysicalPathTransition()
        settle(&transition, wifiA, at: 0)
        _ = transition.observeUnavailable()
        let generation = try XCTUnwrap(transition.observeUsable(signature: wifiA))
        XCTAssertEqual(transition.settle(generation, signature: wifiA, at: 1), .changed(restored: true))
    }

    func testRepeatedUpdateKeepsTheRunningSettleTimer() throws {
        var transition = TunnelPhysicalPathTransition()
        let generation = try XCTUnwrap(transition.observeUsable(signature: wifiA))
        XCTAssertNil(transition.observeUsable(signature: wifiA))
        XCTAssertTrue(transition.isCurrent(generation))
        XCTAssertEqual(transition.settle(generation, signature: wifiA, at: 0), .baseline)
    }

    func testSupersededSettleIsIgnored() throws {
        var transition = TunnelPhysicalPathTransition()
        settle(&transition, wifiA, at: 0)
        let stale = try XCTUnwrap(transition.observeUsable(signature: cellA))
        let current = try XCTUnwrap(transition.observeUsable(signature: wifiB))
        XCTAssertNil(transition.settle(stale, signature: cellA, at: 1))
        XCTAssertEqual(transition.settle(current, signature: wifiB, at: 1), .changed(restored: false))
    }

    // A6: an attach that reports its gateway after its interface refines the
    // path it just recovered instead of kicking the re-dialed connections again.
    func testLateGatewayInsideTheGraceRefinesThePath() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        settle(&transition, wifiA, at: 0)
        XCTAssertEqual(settle(&transition, cellA, at: 10), .changed(restored: false))
        var withGateway = cellA
        withGateway.gateways = ["10.20.30.1"]
        XCTAssertEqual(settle(&transition, withGateway, at: 12), .refined)
        XCTAssertEqual(transition.lastCause, .lateGateway)
    }

    func testLateGatewayAfterTheFirstPathRefinesIt() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        var bare = wifiA
        bare.gateways = []
        XCTAssertEqual(settle(&transition, bare, at: 0), .baseline)
        XCTAssertEqual(settle(&transition, wifiA, at: 2), .refined)
    }

    func testGatewayChangeAfterTheGraceRecovers() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        settle(&transition, wifiA, at: 0)
        var otherRouter = wifiA
        otherRouter.gateways = ["192.168.1.254"]
        XCTAssertEqual(settle(&transition, otherRouter, at: 60), .changed(restored: false))
        XCTAssertEqual(transition.lastCause, .gateway)
    }

    func testZeroGraceRecoversEveryGatewayChange() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 0)
        settle(&transition, wifiA, at: 0)
        var otherRouter = wifiA
        otherRouter.gateways = ["192.168.1.254"]
        XCTAssertEqual(settle(&transition, otherRouter, at: 0.5), .changed(restored: false))
    }

    // A6: Wi-Fi A to B on the same interface behind the same gateway address,
    // with no unusable path in between, used to be no change at all.
    func testSameInterfaceAndGatewayWithANewAddressRecovers() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        settle(&transition, wifiA, at: 0)
        XCTAssertEqual(settle(&transition, wifiB, at: 60), .changed(restored: false))
        XCTAssertEqual(transition.lastCause, .address)
    }

    func testAnAddressGoneWithALateGatewayStillRecovers() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        settle(&transition, wifiA, at: 0)
        var moved = wifiB
        moved.gateways = ["192.168.7.1"]
        XCTAssertEqual(settle(&transition, moved, at: 1), .changed(restored: false))
        XCTAssertEqual(transition.lastCause, .address)
    }

    func testAnAddressAddedInAFamilyInUseRefinesThePath() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        var dualStack = wifiA
        dualStack.addresses = ["192.168.1.20", "2001:db8:1:2::/64"]
        settle(&transition, dualStack, at: 0)
        var secondPrefix = dualStack
        secondPrefix.addresses = (dualStack.addresses + ["2001:db8:9:9::/64"]).sorted()
        XCTAssertEqual(settle(&transition, secondPrefix, at: 60), .refined)
        XCTAssertEqual(transition.lastCause, .addressAdded)
    }

    // an IPv6 address arriving after the IPv4 one lets a v6 transport that
    // failed its dial and is backing off dial now
    func testANewAddressFamilyRecovers() {
        var transition = TunnelPhysicalPathTransition(lateGatewayGrace: 5)
        settle(&transition, wifiA, at: 0)
        var dualStack = wifiA
        dualStack.addresses = ["192.168.1.20", "2001:db8:1:2::/64"]
        dualStack.gateways = ["192.168.1.1", "fe80::1"]
        XCTAssertEqual(settle(&transition, dualStack, at: 1), .changed(restored: false))
        XCTAssertEqual(transition.lastCause, .family)
    }

    func testAddressIdentityKeepsIpv4AndTheIpv6Prefix() {
        XCTAssertEqual(tunnelAddressIdentity(family: AF_INET, bytes: [192, 168, 1, 20]), "192.168.1.20")
        XCTAssertNil(tunnelAddressIdentity(family: AF_INET, bytes: [127, 0, 0, 1]))
        let global: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0x00, 0x02,
                               0xaa, 0xaa, 0xbb, 0xbb, 0xcc, 0xcc, 0xdd, 0xdd]
        XCTAssertEqual(tunnelAddressIdentity(family: AF_INET6, bytes: global), "2001:db8:1:2::/64")
        // a privacy address rotating inside its prefix is the same network
        var rotated = global
        rotated[15] = 0x01
        XCTAssertEqual(tunnelAddressIdentity(family: AF_INET6, bytes: rotated), "2001:db8:1:2::/64")
        let linkLocal: [UInt8] = [0xfe, 0x80] + Array(repeating: 0, count: 13) + [1]
        XCTAssertNil(tunnelAddressIdentity(family: AF_INET6, bytes: linkLocal))
        let loopback: [UInt8] = Array(repeating: 0, count: 15) + [1]
        XCTAssertNil(tunnelAddressIdentity(family: AF_INET6, bytes: loopback))
    }

    func testInterfaceAddressIdentitiesReadsOnlyTheNamedInterfaces() {
        XCTAssertEqual(tunnelInterfaceAddressIdentities(interfaceNames: []), [])
        XCTAssertEqual(tunnelInterfaceAddressIdentities(interfaceNames: ["no-such-interface9"]), [])
        // loopback's own addresses identify no network; a host may add aliases
        let loopback = tunnelInterfaceAddressIdentities(interfaceNames: ["lo0"])
        XCTAssertFalse(loopback.contains { $0.hasPrefix("127.") || $0.hasPrefix("fe80:") || $0 == "0:0:0:0::/64" })
        XCTAssertEqual(loopback, Array(Set(loopback)).sorted())
    }

    func testUnavailableEdgeAbandonsThePendingSettle() throws {
        var transition = TunnelPhysicalPathTransition()
        settle(&transition, wifiA, at: 0)
        let pending = try XCTUnwrap(transition.observeUsable(signature: cellA))
        _ = transition.observeUnavailable()
        XCTAssertNil(transition.settle(pending, signature: cellA, at: 1))
        // the same path returning is not deduplicated against the abandoned settle
        let returned = try XCTUnwrap(transition.observeUsable(signature: cellA))
        XCTAssertEqual(transition.settle(returned, signature: cellA, at: 2), .changed(restored: true))
    }

    func testWifiSignalUsesStableFiveLevelBuckets() {
        XCTAssertEqual(tunnelWifiSignalLevel(0.99), 4)
        XCTAssertEqual(tunnelWifiSignalLevel(0.81), 4)
        XCTAssertEqual(tunnelWifiSignalLevel(0.79), 3)
        XCTAssertEqual(tunnelWifiSignalLevel(0.0), 0)
        XCTAssertNil(tunnelWifiSignalLevel(nil))
    }

    func testFirstDelayedWifiSignalIsOnlyABaseline() {
        var tracker = TunnelNetworkQualityTracker()
        let unavailable = TunnelNetworkQuality(
            expensive: false, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: nil
        )
        let strong = TunnelNetworkQuality(
            expensive: false, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: 4
        )
        let weak = TunnelNetworkQuality(
            expensive: false, constrained: false, supportsDns: true,
            supportsIpv4: true, supportsIpv6: true, cellularTypes: [], wifiSignalLevel: 1
        )
        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: unavailable))
        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: strong))
        XCTAssertTrue(tracker.observe(pathSignature: "wifi-a", quality: weak))
        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: unavailable))
        XCTAssertFalse(tracker.observe(pathSignature: "wifi-a", quality: weak))
    }

    func testCellularTypeOnlyAppliesToTheActiveCellularPath() {
        XCTAssertEqual(
            tunnelActiveCellularTypes(
                usesCellular: false,
                dataServiceIdentifier: "secondary",
                serviceTypes: ["primary": "5g", "secondary": "lte"]
            ), []
        )
        XCTAssertEqual(
            tunnelActiveCellularTypes(
                usesCellular: true,
                dataServiceIdentifier: "secondary",
                serviceTypes: ["primary": "5g", "secondary": "lte"]
            ),
            ["lte"]
        )
        XCTAssertEqual(
            tunnelActiveCellularTypes(
                usesCellular: true,
                dataServiceIdentifier: nil,
                serviceTypes: ["primary": "5g", "secondary": "lte"]
            ),
            ["5g", "lte"]
        )
    }

    func testRepeatedSettingsFailureHasOneScheduledNudgeBudget() throws {
        var owner = TunnelReadinessOwner()
        let state = TunnelReadinessOwner.State(readiness: .local, dnsOwned: false)
        let first = try XCTUnwrap(owner.begin(state))
        XCTAssertEqual(owner.complete(first, succeeded: false), .failed(retry: true))
        let retry = try XCTUnwrap(owner.begin(state))
        XCTAssertEqual(owner.complete(retry, succeeded: false), .failed(retry: false))
        // A later real event is not suppressed by a cached failure.
        XCTAssertNotNil(owner.begin(state))
    }

    func testStaleSettingsCompletionCannotCommitReplacementOrSpendRetry() throws {
        var owner = TunnelReadinessOwner()
        let first = try XCTUnwrap(owner.begin(.init(readiness: .local, dnsOwned: false)))
        let replacement = try XCTUnwrap(owner.begin(.init(readiness: .connected, dnsOwned: true)))
        XCTAssertEqual(owner.complete(first, succeeded: false), .stale)
        XCTAssertEqual(owner.complete(replacement, succeeded: true), .applied)
        owner.invalidate()
        XCTAssertEqual(owner.complete(replacement, succeeded: false), .stale)
    }

    func testSettingsStateReturningToAppliedLevelSupersedesPendingChange() throws {
        var owner = TunnelReadinessOwner()
        let local = TunnelReadinessOwner.State(readiness: .local, dnsOwned: false)
        let initial = try XCTUnwrap(owner.begin(local))
        XCTAssertEqual(owner.complete(initial, succeeded: true), .applied)
        let pending = try XCTUnwrap(owner.begin(.init(readiness: .connected, dnsOwned: true)))
        let backToLocal = try XCTUnwrap(owner.begin(local))
        XCTAssertEqual(owner.complete(pending, succeeded: true), .stale)
        XCTAssertEqual(owner.complete(backToLocal, succeeded: true), .applied)
    }

    func testUnusedCorruptDefaultCannotDenySavedDestination() throws {
        let plan = try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { "saved" }, loadDefault: { throw FixtureError.read }, bestAvailable: { "best" },
            isCurrent: { true }, apply: { XCTAssertEqual($0.location, "saved") }
        )
        XCTAssertEqual(plan.stage, .saved)
    }

    func testExplicitDisconnectSkipsUnrelatedUnreadableDestinationRecords() throws {
        let plan = try restoreTunnelDestination(
            intent: .disconnect, savedLocationHasCurrentOwner: true,
            loadSaved: { () throws -> String? in throw FixtureError.read },
            loadDefault: { throw FixtureError.read }, bestAvailable: { "best" },
            isCurrent: { true }, apply: { XCTAssertNil($0.location) }
        )
        XCTAssertEqual(plan.stage, .explicitDisconnect)
    }

    func testPrivateReadErrorProducesOnlyFixedStageBreadcrumb() {
        var lines: [String] = []
        XCTAssertThrowsError(try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { () throws -> String? in
                throw NSError(domain: "private-marker", code: 91, userInfo: [NSLocalizedDescriptionKey: "/private-marker/token"])
            },
            loadDefault: { nil }, bestAvailable: { "best" }, isCurrent: { true },
            apply: { _ in XCTFail("read failed") },
            report: { lines.append($0 + ":" + $1) }
        ))
        XCTAssertEqual(lines, ["saved-load:failed"])
        XCTAssertFalse(lines.joined().contains("private-marker"))
    }

    func testFailedIntentReadThenSameOldConnectCannotUndoLiveDisconnect() {
        let disconnect = Date(timeIntervalSince1970: 200)
        var liveDisconnectAt: Date?
        var observedIntent: String? = "old-connect"
        XCTAssertThrowsError(try recordTunnelLiveDisconnect(
            at: disconnect, readIntent: { throw FixtureError.read },
            liveDisconnectAt: &liveDisconnectAt, observedIntent: &observedIntent
        ))
        XCTAssertEqual(liveDisconnectAt, disconnect)
        XCTAssertEqual(observedIntent, "old-connect")
        XCTAssertFalse(tunnelConnectIntentIsNewer(changedAt: Date(timeIntervalSince1970: 100), liveDisconnectAt: liveDisconnectAt))
        XCTAssertFalse(tunnelConnectIntentIsNewer(changedAt: disconnect, liveDisconnectAt: liveDisconnectAt))
        XCTAssertTrue(tunnelConnectIntentIsNewer(changedAt: Date(timeIntervalSince1970: 201), liveDisconnectAt: liveDisconnectAt))
    }

    func testZeroExitWakeCannotBeDeclaredHealthyByZeroScheduledProbes() {
        XCTAssertEqual(tunnelWakeAction(
            connectIntended: true, destinationPresent: true, consumerPresent: true,
            providerCount: 0, afterGrace: true, pathRecoveryAlreadyRequested: false
        ), .recoverTransport)
    }

    func testMissingIntendedConsumerIsNotCoveredByTransportOnlyPathRecovery() {
        XCTAssertEqual(tunnelWakeAction(
            connectIntended: true, destinationPresent: false, consumerPresent: false,
            providerCount: 0, afterGrace: true, pathRecoveryAlreadyRequested: true
        ), .restoreDestination)
    }

    func testIntentionalDisconnectAndProvideOnlyWakeDoNotConstructConsumer() {
        XCTAssertEqual(tunnelWakeAction(
            connectIntended: false, destinationPresent: false, consumerPresent: false,
            providerCount: 0, afterGrace: true, pathRecoveryAlreadyRequested: false
        ), .local)
    }

    func testHealthyWindowWakeKeepsExistingConsumer() {
        XCTAssertEqual(tunnelWakeAction(
            connectIntended: true, destinationPresent: true, consumerPresent: true,
            providerCount: 2, afterGrace: true, pathRecoveryAlreadyRequested: false
        ), .probeExisting)
    }

    func testExistingEmptyWindowDoesNotDuplicateOwnedPathRecovery() {
        XCTAssertEqual(tunnelWakeAction(
            connectIntended: true, destinationPresent: true, consumerPresent: true,
            providerCount: 0, afterGrace: true, pathRecoveryAlreadyRequested: true
        ), .coveredByPathRecovery)
    }

    func testNoDnsInterceptorCannotAdvertiseSyntheticResolver() {
        XCTAssertEqual(tunnelOwnedDnsServers(interceptorPresent: false, advertised: ["synthetic-mask"]), [])
    }

    func testLiveDnsInterceptorPreservesSdkSelectionWithoutInventedFallback() {
        XCTAssertEqual(tunnelOwnedDnsServers(interceptorPresent: true, advertised: ["selected-resolver"]), ["selected-resolver"])
        XCTAssertEqual(tunnelOwnedDnsServers(interceptorPresent: true, advertised: []), [])
    }

    func testTunnelStartupFlushesCompletedBreadcrumbBeforeCompletion() {
        var events: [String] = []
        finishTunnelStartup(
            recordOutcome: { events.append("completed") },
            flushLogs: { events.append("flush") },
            completion: { events.append("completion") }
        )
        XCTAssertEqual(events, ["completed", "flush", "completion"])
    }

    func testTunnelStopJoinTimeoutIsReportedBeforeFinalFlushAndStillCompletes() {
        var events: [String] = []
        finishTunnelStop(
            cleanup: { events.append("cleanup") },
            joinCleanup: {
                events.append("join")
                return false
            },
            reportCleanupJoin: { joined in
                events.append(joined ? "joined" : "timeout")
            },
            sampleFinalState: { events.append("final-sample") },
            flushLogs: { events.append("flush") },
            completion: { events.append("completion") }
        )
        XCTAssertEqual(
            events,
            ["cleanup", "join", "timeout", "final-sample", "flush", "completion"]
        )
        XCTAssertEqual(tunnelStopCloseJoinTimeoutMilliseconds, 250)
    }

    func testAppUpdateStopHasDistinctSecretFreeClassification() {
        XCTAssertEqual(tunnelStopReasonClass(.appUpdate), "app-update")
    }

    func testRecoveryTimingDefaultsSettleInsideOneKickSpacing() {
        let timing = TunnelRecoveryTiming()
        // A transition burst settles, and the defaultPath re-check lands,
        // inside one kick spacing, so neither postpones the kick that a
        // settled change earns.
        XCTAssertLessThan(timing.pathSettleDelay, timing.minimumKickInterval)
        XCTAssertLessThan(timing.defaultPathRecheckDelay, timing.minimumKickInterval)
        // The kick owed across a sleep spends its spacing before the wake
        // grace judges the window, so a wake-unhealthy kick is not postponed.
        XCTAssertGreaterThan(timing.wakeHealthGrace, timing.minimumKickInterval)
        XCTAssertGreaterThan(timing.wifiQualitySampleInterval, timing.wifiQualitySampleLeeway)
        // the late half of a change settles after it, so the grace must
        // outlast the settle delay to absorb it
        XCTAssertGreaterThan(timing.lateGatewayGrace, timing.pathSettleDelay)
    }

    // The switch timeline in NETWORKSWITCH.md is built on these two.
    func testRecoveryTimingDefaultsMatchTheSwitchTimeline() {
        let timing = TunnelRecoveryTiming()
        XCTAssertEqual(timing.pathSettleDelay, 0.350)
        XCTAssertEqual(timing.minimumKickInterval, 2)
    }

    private enum FixtureError: Error { case read, write }

    private func supersededError() -> NSError {
        NSError(domain: "go", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"
        ])
    }
}
