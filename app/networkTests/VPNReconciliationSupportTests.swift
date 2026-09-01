//
//  VPNReconciliationSupportTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

struct VPNReconciliationSupportTests {

    @Test func desiredStateRunsForProviding() {
        let state = VPNDesiredState(provideEnabled: true)
        #expect(state.shouldRun)
    }

    @Test func desiredStateRunsForConnecting() {
        let state = VPNDesiredState(connectEnabled: true)
        #expect(state.shouldRun)
    }

    @Test func desiredStateRunsForRemoteRouting() {
        let state = VPNDesiredState(routeLocal: false)
        #expect(state.shouldRun)
    }

    @Test func desiredStateStopsWhenNoPacketRoutingIsNeeded() {
        let state = VPNDesiredState()
        #expect(!state.shouldRun)
    }

    @Test func firstHealthFailureRestartsCurrentProfileInPlace() {
        #expect(
            vpnTunnelRecoveryAction(index: 0, reset: false, managerCount: 1)
                == .restartCurrentProfileInPlace
        )
    }

    @Test func resetHealthFailureAdvancesToNextProfile() {
        #expect(
            vpnTunnelRecoveryAction(index: 0, reset: true, managerCount: 2)
                == .tryNextProfile(1)
        )
    }

    @Test func finalResetHealthFailureIsReported() {
        #expect(
            vpnTunnelRecoveryAction(index: 0, reset: true, managerCount: 1)
                == .reportFailure
        )
    }

    @Test func newProfileFinalResetHealthFailureIsReported() {
        #expect(
            vpnTunnelRecoveryAction(index: 0, reset: true, managerCount: 0)
                == .reportFailure
        )
    }

    @Test func profileRemovalHasAFiniteAttemptBudget() {
        #expect(vpnProfileRemovalMayContinue(attempt: MaximumVPNProfilesToRemove - 1))
        #expect(!vpnProfileRemovalMayContinue(attempt: MaximumVPNProfilesToRemove))
    }

    @Test func activeExistingProfileStopsBeforeConfigurationReplacement() {
        #expect(vpnTunnelNeedsStopBeforeConfiguration(
            profileExists: true,
            connectionState: .connected
        ))
    }

    @Test func activeExistingProfileStopsBeforeRecoveryRestart() {
        #expect(vpnTunnelNeedsStopBeforeConfiguration(
            profileExists: true,
            connectionState: .reasserting
        ))
    }

    @Test func disconnectedExistingProfileConfiguresWithoutRedundantStop() {
        #expect(!vpnTunnelNeedsStopBeforeConfiguration(
            profileExists: true,
            connectionState: .disconnected
        ))
    }

    @Test func newProfileConfiguresWithoutStop() {
        #expect(!vpnTunnelNeedsStopBeforeConfiguration(
            profileExists: false,
            connectionState: .connected
        ))
    }

    @Test func timedOutSystemOperationDoesNotRetryConcurrently() {
        let error = VPNOperationTimeoutError(operation: "test", timeout: 1)
        #expect(!vpnOperationMayRetryImmediately(after: error))
    }

    @Test func completedSystemErrorMayUseBoundedRetry() {
        let error = NSError(
            domain: "VPNReconciliationSupportTests",
            code: 1
        )
        #expect(vpnOperationMayRetryImmediately(after: error))
    }

    @Test func successfulLatePreferenceWriteReconcilesCurrentState() {
        #expect(vpnLatePreferenceWriteNeedsReconcile(
            isClosed: false,
            error: nil
        ))
    }

    @Test func failedLatePreferenceWriteDoesNotLoopReconciliation() {
        #expect(!vpnLatePreferenceWriteNeedsReconcile(
            isClosed: false,
            error: NSError(
                domain: "VPNReconciliationSupportTests",
                code: 2
            )
        ))
    }

    @Test func latePreferenceWriteDoesNothingAfterManagerClose() {
        #expect(!vpnLatePreferenceWriteNeedsReconcile(
            isClosed: true,
            error: nil
        ))
    }

    @Test func foregroundDoesNothingAfterManagerClose() {
        #expect(
            vpnForegroundRetryAction(
                isClosed: true,
                reconcileInFlight: false,
                hasError: true
            ) == .none
        )
    }

    @Test func foregroundForcesLiveHealthInspection() {
        #expect(
            vpnForegroundRetryAction(
                isClosed: false,
                reconcileInFlight: false,
                hasError: false
            ) == .forceReconcile
        )
    }

    @Test func foregroundDoesNotDuplicateHealthyInFlightReconcile() {
        #expect(
            vpnForegroundRetryAction(
                isClosed: false,
                reconcileInFlight: true,
                hasError: false
            ) == .none
        )
    }

    @Test func foregroundForcesFailedIdleReconcile() {
        #expect(
            vpnForegroundRetryAction(
                isClosed: false,
                reconcileInFlight: false,
                hasError: true
            ) == .forceReconcile
        )
    }

    @Test func foregroundQueuesFailureWhilePriorReconcileFinishes() {
        #expect(
            vpnForegroundRetryAction(
                isClosed: false,
                reconcileInFlight: true,
                hasError: true
            ) == .forceReconcile
        )
    }

    @Test func matchingConnectedTunnelIsAdoptedWithoutRestart() {
        let identity = testTunnelIdentity()
        #expect(vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connected,
            installedIdentity: identity,
            desiredIdentity: identity
        ))
    }

    @Test func matchingConnectingTunnelIsAdoptedForBoundedHealthCheck() {
        let identity = testTunnelIdentity()
        #expect(vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connecting,
            installedIdentity: identity,
            desiredIdentity: identity
        ))
    }

    @Test func matchingReassertingTunnelIsAdoptedForBoundedHealthCheck() {
        let identity = testTunnelIdentity()
        #expect(vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .reasserting,
            installedIdentity: identity,
            desiredIdentity: identity
        ))
    }

    @Test func disconnectedTunnelIsNotAdopted() {
        let identity = testTunnelIdentity()
        #expect(!vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .disconnected,
            installedIdentity: identity,
            desiredIdentity: identity
        ))
    }

    @Test func connectedTunnelRequiresLiveRpcAndStartedState() {
        #expect(vpnTunnelHealthIsSatisfied(
            expectedStarted: true,
            connectionState: .connected,
            rpcConnected: true,
            sdkTunnelStarted: true,
            requiresProvider: false,
            providerCount: 0
        ))
        #expect(!vpnTunnelHealthIsSatisfied(
            expectedStarted: true,
            connectionState: .connected,
            rpcConnected: false,
            sdkTunnelStarted: true,
            requiresProvider: false,
            providerCount: 0
        ))
        #expect(!vpnTunnelHealthIsSatisfied(
            expectedStarted: true,
            connectionState: .connected,
            rpcConnected: true,
            sdkTunnelStarted: false,
            requiresProvider: false,
            providerCount: 0
        ))
    }

    @Test func remoteTunnelRequiresAReadyProviderWindow() {
        #expect(!vpnTunnelHealthIsSatisfied(
            expectedStarted: true,
            connectionState: .connected,
            rpcConnected: true,
            sdkTunnelStarted: true,
            requiresProvider: true,
            providerCount: 0
        ))
        #expect(vpnTunnelHealthIsSatisfied(
            expectedStarted: true,
            connectionState: .connected,
            rpcConnected: true,
            sdkTunnelStarted: true,
            requiresProvider: true,
            providerCount: 1
        ))
    }

    @Test func connectingAndReassertingAreNeverHealthy() {
        for state in [VPNTunnelConnectionState.connecting, .reasserting] {
            #expect(!vpnTunnelHealthIsSatisfied(
                expectedStarted: true,
                connectionState: state,
                rpcConnected: true,
                sdkTunnelStarted: true,
                requiresProvider: false,
                providerCount: 1
            ))
        }
    }

    @Test func stoppedHealthUsesNetworkExtensionStatusNotCachedSdkState() {
        #expect(vpnTunnelHealthIsSatisfied(
            expectedStarted: false,
            connectionState: .disconnected,
            rpcConnected: true,
            sdkTunnelStarted: true,
            requiresProvider: true,
            providerCount: 1
        ))
        #expect(!vpnTunnelHealthIsSatisfied(
            expectedStarted: false,
            connectionState: .disconnecting,
            rpcConnected: false,
            sdkTunnelStarted: false,
            requiresProvider: false,
            providerCount: 0
        ))
    }

    @Test func statusAuditTimingRepairsDisconnectsAndGracesTransitions() {
        #expect(vpnTunnelHealthAuditDelay(
            shouldRun: true,
            reconcileInFlight: false,
            connectionState: .disconnected,
            isHealthy: false
        ) == 0)
        #expect(vpnTunnelHealthAuditDelay(
            shouldRun: true,
            reconcileInFlight: false,
            connectionState: .reasserting,
            isHealthy: false
        ) == VPNTransitionalHealthAuditDelay)
        #expect(vpnTunnelHealthAuditDelay(
            shouldRun: true,
            reconcileInFlight: false,
            connectionState: .connected,
            isHealthy: true
        ) == nil)
        #expect(vpnTunnelHealthAuditDelay(
            shouldRun: true,
            reconcileInFlight: true,
            connectionState: .disconnected,
            isHealthy: false
        ) == nil)
        #expect(vpnTunnelHealthAuditDelay(
            shouldRun: false,
            reconcileInFlight: false,
            connectionState: .connected,
            isHealthy: false
        ) == VPNDisconnectedHealthAuditDelay)
        #expect(vpnTunnelHealthAuditDelay(
            shouldRun: false,
            reconcileInFlight: false,
            connectionState: .disconnected,
            isHealthy: true
        ) == nil)
    }

    @Test func mismatchedTunnelConfigurationIsNotAdopted() {
        let identity = testTunnelIdentity()
        let otherIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: identity.rpcListenHostPort,
            rpcServerPem: identity.rpcServerPem,
            rpcClientPem: identity.rpcClientPem,
            networkSpaceJson: "{\"env\":\"other\"}",
            instanceId: identity.instanceId
        )
        #expect(!vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connected,
            installedIdentity: identity,
            desiredIdentity: otherIdentity
        ))
    }

    @Test func instanceMismatchCannotBeAdoptedByDeviceRemote() {
        let identity = testTunnelIdentity()
        let relaunchedAppIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: identity.rpcListenHostPort,
            rpcServerPem: identity.rpcServerPem,
            rpcClientPem: identity.rpcClientPem,
            networkSpaceJson: identity.networkSpaceJson,
            instanceId: "new-app-process-instance"
        )
        #expect(!vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connected,
            installedIdentity: identity,
            desiredIdentity: relaunchedAppIdentity
        ))
    }

    @Test func bootstrapCanRecoverInstanceFromAuthenticatedRunningTunnel() {
        let identity = testTunnelIdentity()
        let bootstrapIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: identity.rpcListenHostPort,
            rpcServerPem: identity.rpcServerPem,
            rpcClientPem: identity.rpcClientPem,
            networkSpaceJson: identity.networkSpaceJson,
            instanceId: ""
        )
        let recovered = vpnRunningTunnelBootstrapIdentity(
            candidates: [
                (
                    connectionState: VPNTunnelConnectionState.connected,
                    identity: Optional(identity)
                ),
            ],
            desiredIdentity: bootstrapIdentity
        )
        #expect(recovered?.instanceId == identity.instanceId)
    }

    @Test func coldProcessRelaunchRecoversDriftedInstanceWithoutRestart() throws {
        let runningIdentity = testTunnelIdentity()
        let driftedLocalIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: runningIdentity.rpcListenHostPort,
            rpcServerPem: runningIdentity.rpcServerPem,
            rpcClientPem: runningIdentity.rpcClientPem,
            networkSpaceJson: runningIdentity.networkSpaceJson,
            instanceId: "instance-created-by-old-jwt-refresh"
        )

        #expect(!vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connected,
            installedIdentity: runningIdentity,
            desiredIdentity: driftedLocalIdentity
        ))

        let recoveredIdentity = try #require(
            vpnRunningTunnelBootstrapIdentity(
                candidates: [
                    (
                        connectionState: VPNTunnelConnectionState.connected,
                        identity: Optional(runningIdentity)
                    ),
                ],
                desiredIdentity: driftedLocalIdentity
            )
        )
        let relaunchedIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: driftedLocalIdentity.rpcListenHostPort,
            rpcServerPem: driftedLocalIdentity.rpcServerPem,
            rpcClientPem: driftedLocalIdentity.rpcClientPem,
            networkSpaceJson: driftedLocalIdentity.networkSpaceJson,
            instanceId: recoveredIdentity.instanceId
        )

        #expect(vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connected,
            installedIdentity: runningIdentity,
            desiredIdentity: relaunchedIdentity
        ))
    }

    @Test func bootstrapRejectsRunningTunnelWithDifferentRpcSession() {
        let identity = testTunnelIdentity()
        let bootstrapIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: "127.0.0.1:12099",
            rpcServerPem: identity.rpcServerPem,
            rpcClientPem: identity.rpcClientPem,
            networkSpaceJson: identity.networkSpaceJson,
            instanceId: ""
        )
        #expect(vpnRunningTunnelBootstrapIdentity(
            candidates: [
                (
                    connectionState: VPNTunnelConnectionState.connected,
                    identity: Optional(identity)
                ),
            ],
            desiredIdentity: bootstrapIdentity
        ) == nil)
    }

    @Test func rpcSessionEnvelopeDistinguishesPendingAndConfirmed() throws {
        let session = testRpcSession()
        let pendingData = try #require(
            RpcSessionStore.encode(session, state: .pending)
        )
        let confirmedData = try #require(
            RpcSessionStore.encode(session, state: .confirmed)
        )

        #expect(RpcSessionStore.decode(pendingData) == .pending(session))
        #expect(RpcSessionStore.decode(confirmedData) == .confirmed(session))
    }

    @Test func rpcSessionEnvelopeRejectsCorruptAndUnknownVersions() throws {
        let corruptResult = RpcSessionStore.decode(Data("not-json".utf8))
        guard case .corrupt = corruptResult else {
            Issue.record("Malformed RPC session was not reported as corrupt")
            return
        }

        let unknownVersion = RpcSessionEnvelope(
            state: .confirmed,
            session: testRpcSession(),
            version: RpcSessionEnvelope.currentVersion + 1
        )
        let unknownData = try JSONEncoder().encode(unknownVersion)
        guard case .corrupt(let reason) = RpcSessionStore.decode(unknownData) else {
            Issue.record("Unknown RPC session version was accepted")
            return
        }
        #expect(reason.contains("unsupported version"))
    }

    @Test func rpcSessionEnvelopeRejectsInvalidTransportMaterial() throws {
        let invalidSession = RpcSession(
            clientPem: "",
            clientCertPem: "client-public",
            serverPem: "server-private",
            serverCertPem: "server-public",
            host: "0.0.0.0",
            port: 0
        )
        #expect(
            RpcSessionStore.encode(invalidSession, state: .confirmed) == nil
        )

        let invalidEnvelope = RpcSessionEnvelope(
            state: .confirmed,
            session: invalidSession
        )
        let invalidData = try JSONEncoder().encode(invalidEnvelope)
        guard case .corrupt(let reason) = RpcSessionStore.decode(invalidData) else {
            Issue.record("Invalid RPC transport material was accepted")
            return
        }
        #expect(reason.contains("invalid session"))
    }

    @Test func explicitProfileResetDoesNotAdoptRunningTunnel() {
        let identity = testTunnelIdentity()
        #expect(!vpnShouldAdoptRunningTunnel(
            reset: true,
            connectionState: .connected,
            installedIdentity: identity,
            desiredIdentity: identity
        ))
    }

    @Test func runningTunnelAdoptionFindsMatchingProfileAfterStaleProfile() {
        let identity = testTunnelIdentity()
        let candidates = [
            (
                connectionState: VPNTunnelConnectionState.disconnected,
                identity: Optional(identity)
            ),
            (
                connectionState: VPNTunnelConnectionState.connected,
                identity: Optional(identity)
            ),
        ]
        #expect(vpnRunningTunnelAdoptionIndex(
            reset: false,
            candidates: candidates,
            desiredIdentity: identity
        ) == 1)
    }

    @Test func runningTunnelAdoptionPrefersConnectedProfile() {
        let identity = testTunnelIdentity()
        let candidates = [
            (
                connectionState: VPNTunnelConnectionState.connecting,
                identity: Optional(identity)
            ),
            (
                connectionState: VPNTunnelConnectionState.connected,
                identity: Optional(identity)
            ),
            (
                connectionState: VPNTunnelConnectionState.reasserting,
                identity: Optional(identity)
            ),
        ]
        #expect(vpnRunningTunnelAdoptionIndex(
            reset: false,
            candidates: candidates,
            desiredIdentity: identity
        ) == 1)
    }

    @Test func runningTunnelAdoptionIgnoresMismatchedActiveProfile() {
        let identity = testTunnelIdentity()
        let mismatchedIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: identity.rpcListenHostPort,
            rpcServerPem: identity.rpcServerPem,
            rpcClientPem: identity.rpcClientPem,
            networkSpaceJson: "{\"env\":\"other\"}",
            instanceId: identity.instanceId
        )
        let candidates = [
            (
                connectionState: VPNTunnelConnectionState.connected,
                identity: Optional(mismatchedIdentity)
            ),
            (
                connectionState: VPNTunnelConnectionState.connected,
                identity: Optional(identity)
            ),
        ]
        #expect(vpnRunningTunnelAdoptionIndex(
            reset: false,
            candidates: candidates,
            desiredIdentity: identity
        ) == 1)
    }

    @Test func runningTunnelAdoptionDoesNotBypassExplicitReset() {
        let identity = testTunnelIdentity()
        let candidates = [
            (
                connectionState: VPNTunnelConnectionState.connected,
                identity: Optional(identity)
            ),
        ]
        #expect(vpnRunningTunnelAdoptionIndex(
            reset: true,
            candidates: candidates,
            desiredIdentity: identity
        ) == nil)
    }

    @Test func operationCallbackCompletesBeforeDeadline() async {
        let callbackCount = LockedCounter()
        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            performVPNOperation(
                operation: "test.callback",
                timeout: 1,
                callbackQueue: .global()
            ) { completion in
                completion(.success(7))
            } completion: { result in
                callbackCount.increment()
                continuation.resume(returning: result)
            }
        }

        #expect((try? result.get()) == 7)
        #expect(callbackCount.value == 1)
    }

    @Test func missingOperationCallbackTimesOut() async {
        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            performVPNOperation(
                operation: "test.missing",
                timeout: 0.02,
                callbackQueue: .global()
            ) { _ in
                // Deliberately never invoke the system callback.
            } completion: { result in
                continuation.resume(returning: result)
            }
        }

        guard case .failure(let error) = result else {
            Issue.record("Expected the missing callback to time out")
            return
        }
        #expect(error is VPNOperationTimeoutError)
    }

    @Test func lateOperationCallbackIsIgnoredAfterTimeout() async {
        let callbackCount = LockedCounter()
        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            performVPNOperation(
                operation: "test.late",
                timeout: 0.02,
                callbackQueue: .global()
            ) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.10) {
                    completion(.success(9))
                }
            } completion: { result in
                callbackCount.increment()
                continuation.resume(returning: result)
            }
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        guard case .failure(let error) = result else {
            Issue.record("Expected the deadline to win")
            return
        }
        #expect(error is VPNOperationTimeoutError)
        #expect(callbackCount.value == 1)
    }

    @Test func lateOperationCallbackIsReportedOnceAfterTimeout() async {
        let primaryCallbackCount = LockedCounter()
        let lateCallbackCount = LockedCounter()
        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            performVPNOperation(
                operation: "test.late-observer",
                timeout: 0.02,
                callbackQueue: .global(),
                lateCompletion: { (result: Result<Int, Error>) in
                    if (try? result.get()) == 9 {
                        lateCallbackCount.increment()
                    }
                }
            ) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.10) {
                    completion(.success(9))
                    completion(.success(10))
                }
            } completion: { result in
                primaryCallbackCount.increment()
                continuation.resume(returning: result)
            }
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        guard case .failure(let error) = result else {
            Issue.record("Expected the deadline to win")
            return
        }
        #expect(error is VPNOperationTimeoutError)
        #expect(primaryCallbackCount.value == 1)
        #expect(lateCallbackCount.value == 1)
    }

    @Test func duplicateOperationCallbackCompletesOnce() async {
        let callbackCount = LockedCounter()
        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            performVPNOperation(
                operation: "test.duplicate",
                timeout: 1,
                callbackQueue: .global()
            ) { completion in
                completion(.success(3))
                completion(.success(4))
            } completion: { result in
                callbackCount.increment()
                continuation.resume(returning: result)
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect((try? result.get()) == 3)
        #expect(callbackCount.value == 1)
    }

    @Test func sharedTunnelJwtEnvelopeRequiresExactInstance() throws {
        let data = try #require(
            SharedTunnelJwtStore.encode(
                byJwt: "fresh.jwt.value",
                instanceId: "instance-a"
            )
        )
        #expect(
            SharedTunnelJwtStore.decode(
                data,
                expectedInstanceId: "instance-a"
            ) == "fresh.jwt.value"
        )
        #expect(
            SharedTunnelJwtStore.decode(
                data,
                expectedInstanceId: "instance-b"
            ) == nil
        )
    }

    @Test func sharedTunnelJwtEnvelopeRejectsUnknownVersionAndEmptyValues() throws {
        let unknown = SharedTunnelJwtEnvelope(
            instanceId: "instance-a",
            byJwt: "jwt",
            version: SharedTunnelJwtEnvelope.currentVersion + 1
        )
        let data = try JSONEncoder().encode(unknown)
        #expect(
            SharedTunnelJwtStore.decode(
                data,
                expectedInstanceId: "instance-a"
            ) == nil
        )
        #expect(
            SharedTunnelJwtStore.encode(
                byJwt: "",
                instanceId: "instance-a"
            ) == nil
        )
    }

    @Test func sharedTunnelJwtFreshnessRejectsDelayedOlderWriter() {
        let instanceId = "instance-a"
        let older = SharedTunnelJwtCandidate(
            account: "older",
            instanceId: instanceId,
            byJwt: "older.jwt",
            issuedAt: 1_000,
            expiresAt: 9_000
        )
        let newer = SharedTunnelJwtCandidate(
            account: "newer",
            instanceId: instanceId,
            byJwt: "newer.jwt",
            issuedAt: 2_000,
            expiresAt: 10_000
        )

        #expect(
            SharedTunnelJwtStore.freshest(
                [newer, older],
                now: 3_000
            ) == newer
        )
        #expect(
            SharedTunnelJwtStore.freshest(
                [older, newer],
                now: 3_000
            ) == newer
        )
    }

    @Test func sharedTunnelJwtFreshnessPrefersUsableTokenOverExpiredToken() {
        let expiredButLaterIssued = SharedTunnelJwtCandidate(
            account: "expired",
            instanceId: "instance-a",
            byJwt: "expired.jwt",
            issuedAt: 4_000,
            expiresAt: 5_000
        )
        let usable = SharedTunnelJwtCandidate(
            account: "usable",
            instanceId: "instance-a",
            byJwt: "usable.jwt",
            issuedAt: 3_000,
            expiresAt: 7_000
        )

        #expect(
            SharedTunnelJwtStore.freshest(
                [expiredButLaterIssued, usable],
                now: 6_000
            ) == usable
        )
    }

    @Test func sharedTunnelJwtV1MigrationRecordRemainsReadable() throws {
        struct LegacyEnvelope: Codable {
            let version: Int
            let instanceId: String
            let byJwt: String
        }
        let data = try JSONEncoder().encode(
            LegacyEnvelope(
                version: 1,
                instanceId: "instance-a",
                byJwt: "legacy.jwt"
            )
        )
        #expect(
            SharedTunnelJwtStore.decode(
                data,
                expectedInstanceId: "instance-a"
            ) == "legacy.jwt"
        )
        #expect(
            SharedTunnelJwtStore.decode(
                data,
                expectedInstanceId: "instance-b"
            ) == nil
        )
    }

    private func testTunnelIdentity() -> VPNTunnelConfigurationIdentity {
        VPNTunnelConfigurationIdentity(
            rpcListenHostPort: "127.0.0.1:12000",
            rpcServerPem: "server",
            rpcClientPem: "client",
            networkSpaceJson: "{\"env\":\"test\"}",
            instanceId: "instance"
        )
    }

    private func testRpcSession() -> RpcSession {
        RpcSession(
            clientPem: "client-private",
            clientCertPem: "client-public",
            serverPem: "server-private",
            serverCertPem: "server-public",
            host: "127.0.0.1",
            port: 12000
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
