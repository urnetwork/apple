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

    private enum FixtureError: Error { case read, write }

    private func supersededError() -> NSError {
        NSError(domain: "go", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"
        ])
    }
}
