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

    @Test func foregroundChecksHealthyIdleStateWithoutForcing() {
        #expect(
            vpnForegroundRetryAction(
                isClosed: false,
                reconcileInFlight: false,
                hasError: false
            ) == .reconcile
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

    @Test func matchingConnectingTunnelIsAdoptedWithoutDuplicateStart() {
        let identity = testTunnelIdentity()
        #expect(vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connecting,
            installedIdentity: identity,
            desiredIdentity: identity
        ))
    }

    @Test func matchingReassertingTunnelIsAdoptedWithoutRestart() {
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

    @Test func providerOwnedInstanceMismatchDoesNotRestartRunningTunnel() {
        let identity = testTunnelIdentity()
        let relaunchedAppIdentity = VPNTunnelConfigurationIdentity(
            rpcListenHostPort: identity.rpcListenHostPort,
            rpcServerPem: identity.rpcServerPem,
            rpcClientPem: identity.rpcClientPem,
            networkSpaceJson: identity.networkSpaceJson,
            instanceId: "new-app-process-instance"
        )
        #expect(vpnShouldAdoptRunningTunnel(
            reset: false,
            connectionState: .connected,
            installedIdentity: identity,
            desiredIdentity: relaunchedAppIdentity
        ))
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

    private func testTunnelIdentity() -> VPNTunnelConfigurationIdentity {
        VPNTunnelConfigurationIdentity(
            rpcListenHostPort: "127.0.0.1:12000",
            rpcServerPem: "server",
            rpcClientPem: "client",
            networkSpaceJson: "{\"env\":\"test\"}",
            instanceId: "instance"
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
