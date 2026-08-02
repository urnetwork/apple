//
//  VPNReconciliationSupport.swift
//  URnetwork
//
//  Small, platform-independent pieces of VPN reconciliation. Keeping these
//  decisions separate from NetworkExtension makes the stall and retry paths
//  deterministic and directly testable.
//

import Foundation

let VPNPreferencesOperationTimeout: TimeInterval = 30
let MaximumVPNProfilesToRemove = 32

struct VPNDesiredState {
    var provideEnabled = false
    var connectEnabled = false
    var routeLocal = true
    var providePaused = false

    var shouldRun: Bool {
        provideEnabled || connectEnabled || !routeLocal
    }
}

enum VPNTunnelRecoveryAction: Equatable {
    // Restart the existing profile without removing it. Removing and then
    // recreating a profile can require fresh system authorization and can
    // strand the app without any usable VPN configuration if that save is
    // delayed or its callback never arrives.
    case restartCurrentProfileInPlace
    case tryNextProfile(Int)
    case reportFailure
}

enum VPNForegroundRetryAction: Equatable {
    case none
    case reconcile
    case forceReconcile
}

enum VPNTunnelConnectionState {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

struct VPNTunnelConfigurationIdentity: Equatable {
    let rpcListenHostPort: String
    let rpcServerPem: String
    let rpcClientPem: String
    let networkSpaceJson: String
    // The app-side DeviceRemote is recreated with the UI process, while the
    // packet-tunnel provider owns the instance ID for its longer lifetime.
    // Retain this field for diagnostics, but do not use it to decide whether
    // the app can authenticate and adopt an existing tunnel.
    let instanceId: String
}

func vpnTunnelConfigurationMatchesForAdoption(
    installedIdentity: VPNTunnelConfigurationIdentity?,
    desiredIdentity: VPNTunnelConfigurationIdentity?
) -> Bool {
    guard let installedIdentity, let desiredIdentity else {
        return false
    }
    return installedIdentity.rpcListenHostPort ==
            desiredIdentity.rpcListenHostPort &&
        installedIdentity.rpcServerPem == desiredIdentity.rpcServerPem &&
        installedIdentity.rpcClientPem == desiredIdentity.rpcClientPem &&
        installedIdentity.networkSpaceJson == desiredIdentity.networkSpaceJson
}

private func vpnTunnelAdoptionPriority(
    _ connectionState: VPNTunnelConnectionState
) -> Int? {
    switch connectionState {
    case .connected:
        return 3
    case .reasserting:
        return 2
    case .connecting:
        return 1
    case .invalid, .disconnected, .disconnecting:
        return nil
    }
}

func vpnShouldAdoptRunningTunnel(
    reset: Bool,
    connectionState: VPNTunnelConnectionState,
    installedIdentity: VPNTunnelConfigurationIdentity?,
    desiredIdentity: VPNTunnelConfigurationIdentity?
) -> Bool {
    guard !reset,
          vpnTunnelConfigurationMatchesForAdoption(
            installedIdentity: installedIdentity,
            desiredIdentity: desiredIdentity
          ) else {
        return false
    }

    switch connectionState {
    case .connecting, .connected, .reasserting:
        return true
    case .invalid, .disconnected, .disconnecting:
        return false
    }
}

func vpnRunningTunnelAdoptionIndex(
    reset: Bool,
    candidates: [(
        connectionState: VPNTunnelConnectionState,
        identity: VPNTunnelConfigurationIdentity?
    )],
    desiredIdentity: VPNTunnelConfigurationIdentity?
) -> Int? {
    guard !reset else {
        return nil
    }

    var selectedIndex: Int?
    var selectedPriority = 0
    for (index, candidate) in candidates.enumerated() {
        guard let priority = vpnTunnelAdoptionPriority(candidate.connectionState),
              priority > selectedPriority,
              vpnShouldAdoptRunningTunnel(
                reset: false,
                connectionState: candidate.connectionState,
                installedIdentity: candidate.identity,
                desiredIdentity: desiredIdentity
              ) else {
            continue
        }
        selectedIndex = index
        selectedPriority = priority
    }
    return selectedIndex
}

func vpnForegroundRetryAction(
    isClosed: Bool,
    reconcileInFlight: Bool,
    hasError: Bool
) -> VPNForegroundRetryAction {
    if isClosed {
        return .none
    }
    if hasError {
        // Queue a forced retry even if the previous request is just finishing.
        // The serialized reconciler will run it after the active generation.
        return .forceReconcile
    }
    if reconcileInFlight {
        return .none
    }
    return .reconcile
}

func vpnTunnelRecoveryAction(
    index: Int,
    reset: Bool,
    managerCount: Int
) -> VPNTunnelRecoveryAction {
    if !reset {
        return .restartCurrentProfileInPlace
    }
    if index + 1 < managerCount {
        return .tryNextProfile(index + 1)
    }
    return .reportFailure
}

func vpnTunnelConnectionIsStopped(
    _ connectionState: VPNTunnelConnectionState
) -> Bool {
    switch connectionState {
    case .invalid, .disconnected:
        return true
    case .connecting, .connected, .reasserting, .disconnecting:
        return false
    }
}

func vpnTunnelNeedsStopBeforeConfiguration(
    profileExists: Bool,
    connectionState: VPNTunnelConnectionState
) -> Bool {
    guard profileExists else {
        return false
    }
    // A recovery is always prepared as a restart, but an already stopped
    // profile does not need another stop request. Likewise, an active profile
    // whose identity did not qualify for adoption must be stopped before its
    // configuration is replaced; startVPNTunnel() does not restart an already
    // running extension with newly saved providerConfiguration.
    return !vpnTunnelConnectionIsStopped(connectionState)
}

func vpnProfileRemovalMayContinue(attempt: Int) -> Bool {
    attempt < MaximumVPNProfilesToRemove
}

struct VPNOperationTimeoutError: LocalizedError {
    let operation: String
    let timeout: TimeInterval

    var errorDescription: String? {
        "Timed out after \(timeout)s waiting for \(operation)"
    }
}

func vpnOperationMayRetryImmediately(after error: Error) -> Bool {
    // A deadline only stops our wait; it cannot cancel the underlying
    // NetworkExtension preferences transaction. Starting a reset/save while
    // that transaction still owns system authorization can race it and create
    // or remove the wrong profile. Foreground activation provides the safe
    // retry boundary after the user resolves authorization.
    !(error is VPNOperationTimeoutError)
}

func vpnLatePreferenceWriteNeedsReconcile(
    isClosed: Bool,
    error: Error?
) -> Bool {
    !isClosed && error == nil
}

/// Resolves an asynchronous system operation exactly once. NetworkExtension
/// preference callbacks can be delayed by system authorization UI and, in
/// practice, may never arrive if that UI is dismissed. The deadline keeps the
/// serialized VPN reconciler from remaining permanently in-flight. Its primary
/// completion remains exactly-once; an optional late completion observes the
/// first real callback after a timeout so a successful delayed preference
/// write can reconcile the current desired state.
final class VPNOperationDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: String
    private let timeout: TimeInterval
    private let callbackQueue: DispatchQueue
    private let completion: (Result<Value, Error>) -> Void
    private let lateCompletion: ((Result<Value, Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var resolved = false
    private var didTimeout = false
    private var deliveredLateCompletion = false

    init(
        operation: String,
        timeout: TimeInterval = VPNPreferencesOperationTimeout,
        callbackQueue: DispatchQueue = .main,
        lateCompletion: ((Result<Value, Error>) -> Void)? = nil,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        self.operation = operation
        self.timeout = timeout
        self.callbackQueue = callbackQueue
        self.lateCompletion = lateCompletion
        self.completion = completion
    }

    func arm() {
        let timeoutWork = DispatchWorkItem { [self] in
            resolveTimeout(
                .failure(
                    VPNOperationTimeoutError(
                        operation: operation,
                        timeout: timeout
                    )
                )
            )
        }

        lock.lock()
        guard !resolved, self.timeoutWork == nil else {
            lock.unlock()
            return
        }
        self.timeoutWork = timeoutWork
        lock.unlock()

        callbackQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        if resolved {
            let shouldDeliverLate =
                didTimeout && !deliveredLateCompletion && lateCompletion != nil
            if shouldDeliverLate {
                deliveredLateCompletion = true
            }
            lock.unlock()
            if shouldDeliverLate, let lateCompletion {
                callbackQueue.async {
                    lateCompletion(result)
                }
            }
            return
        }
        resolved = true
        let timeoutWork = self.timeoutWork
        self.timeoutWork = nil
        lock.unlock()

        timeoutWork?.cancel()
        callbackQueue.async { [completion] in
            completion(result)
        }
    }

    private func resolveTimeout(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        didTimeout = true
        self.timeoutWork = nil
        lock.unlock()

        callbackQueue.async { [completion] in
            completion(result)
        }
    }
}

@discardableResult
func performVPNOperation<Value>(
    operation: String,
    timeout: TimeInterval = VPNPreferencesOperationTimeout,
    callbackQueue: DispatchQueue = .main,
    lateCompletion: ((Result<Value, Error>) -> Void)? = nil,
    start: (@escaping (Result<Value, Error>) -> Void) -> Void,
    completion: @escaping (Result<Value, Error>) -> Void
) -> VPNOperationDeadline<Value> {
    let deadline = VPNOperationDeadline<Value>(
        operation: operation,
        timeout: timeout,
        callbackQueue: callbackQueue,
        lateCompletion: lateCompletion,
        completion: completion
    )
    deadline.arm()
    start { result in
        deadline.resolve(result)
    }
    return deadline
}
