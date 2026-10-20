//
//  VPNReconciliationSupport.swift
//  URnetwork
//
//  Small, platform-independent pieces of VPN reconciliation. Keeping these
//  decisions separate from NetworkExtension makes the stall and retry paths
//  deterministic and directly testable.
//

import Foundation

/// Removal must not hide an unresolved provider logout (including a deadline).
/// Both callbacks are admitted once on the main actor, as in VPNManager.
@MainActor
func performVPNLogoutCleanup(
    notifyProviders: (@escaping (Error?) -> Void) -> Void,
    removeProfiles: @escaping (@escaping (Error?) -> Void) -> Void,
    completion: @escaping (Error?) -> Void
) {
    var providersCompleted = false
    var removalCompleted = false
    notifyProviders { providerError in
        guard !providersCompleted else { return }
        providersCompleted = true
        removeProfiles { removalError in
            guard !removalCompleted else { return }
            removalCompleted = true
            completion(providerError ?? removalError)
        }
    }
}

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
    case forceReconcile
}

enum VPNTunnelConnectionState: Equatable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

/// The containing app's VPN timing and bounds: health audits, recovery,
/// preference operations and profile cleanup. Each default lives here;
/// VPNManager owns one instance and passes it to the helpers below, so a test
/// or caller can run with its own values.
struct VPNManagerSettings: Equatable {
    // Every value is in seconds unless it says otherwise.

    /// A desired tunnel found disconnected is repaired after this; 0 repairs
    /// it in the same turn.
    var disconnectedAuditDelay: TimeInterval = 0
    /// A desired tunnel found disconnecting is checked again after this, once
    /// the stop it is in has had time to finish.
    var disconnectingAuditDelay: TimeInterval = 1
    /// A connected tunnel whose RPC or provider window is not ready yet.
    var connectedBackendAuditDelay: TimeInterval = 3
    /// Connecting or reasserting tunnels get this long to settle.
    var transitionalAuditDelay: TimeInterval = 5
    /// An app-visible network path change is audited after this.
    var appPathAuditDelay: TimeInterval = 1
    /// Once the RPC connects, the provider window gets this long before every
    /// layer is verified.
    var rpcConnectedAuditDelay: TimeInterval = 1
    /// The health window after a start, and after adopting a running tunnel
    /// whose RPC sync has not been checked (transitionalAuditDelay).
    var tunnelCheckTimeout: TimeInterval = 10
    /// How often a health wait reads the tunnel again. Short, because a wait
    /// ends on the first healthy read. Must be positive: 0 would poll on every
    /// main-queue turn.
    var healthPollInterval: TimeInterval = 0.250
    /// How long the app keeps waiting on a tunnel that is recovering on its
    /// own (`vpnTunnelRecoveryInProgress`) before restarting it anyway. A
    /// window that never formed latches `failed` after its own silent rebuild
    /// (two 45 s outcome deadlines); one that lost its exits mid-session never
    /// latches, so this bound still restarts an extension that answers but
    /// stopped recovering. 0 restarts at the grace deadline.
    var recoveryPatience: TimeInterval = 120
    /// Listener bursts within this coalesce into one reconcile; 0 reconciles
    /// every event.
    var stateBurstCoalesceDelay: TimeInterval = 0.020
    /// Cold-launch bootstrap and JWT refresh give up on the profile lookup
    /// after this, so a slow preferences daemon cannot hold launch.
    var bootstrapLookupTimeout: TimeInterval = 2
    /// A background refresh task may keep validating the tunnel's health for
    /// this long, inside the system's refresh budget.
    var backgroundHealthLease: TimeInterval = 25
    /// A new RPC session that has not connected by this is dropped and the
    /// tunnel reconciled again.
    var rpcConnectTimeout: TimeInterval = 15
    /// A preferences load, save or remove that has not called back by this is
    /// reported as timed out (performVPNOperation).
    var preferencesOperationTimeout: TimeInterval = 30
    /// Logout waits this long on each tunnel provider's reply, so an
    /// unresponsive extension cannot hold the sign-out.
    var providerLogoutMessageTimeout: TimeInterval = 2
    /// Removing every profile stops after this many removals (a count) even
    /// when the preference set never reads empty.
    var maximumProfilesToRemove = 32
    /// A profile JWT save that finished after a newer rotation re-converges
    /// the profile at most this many more times (a count); 0 never retries.
    var profileJwtConvergeAttempts = 3
}

/// NetworkExtension status is the process-level source of truth, while the RPC
/// and SDK values prove that the containing app can actually reach a started,
/// usable tunnel. Cached SDK state alone must never make a dead provider look
/// healthy.
func vpnTunnelHealthIsSatisfied(
    expectedStarted: Bool,
    connectionState: VPNTunnelConnectionState,
    rpcConnected: Bool,
    sdkTunnelStarted: Bool,
    requiresProvider: Bool,
    providerCount: Int
) -> Bool {
    guard expectedStarted else {
        return vpnTunnelConnectionIsStopped(connectionState)
    }
    guard connectionState == .connected,
          rpcConnected,
          sdkTunnelStarted else {
        return false
    }
    return !requiresProvider || providerCount > 0
}

/// Whether a started tunnel that is not healthy yet is still recovering by
/// itself: the extension answers, its SDK tunnel runs, and its window is
/// forming without having given up. A restart then only repeats that work --
/// sign-in and window formation from nothing -- and drops every app's traffic
/// while the tunnel comes back, so it is never faster than waiting. The window
/// reports `failed` when forming stops working, which hands the decision back
/// to a restart.
func vpnTunnelRecoveryInProgress(
    connectionState: VPNTunnelConnectionState,
    rpcConnected: Bool,
    sdkTunnelStarted: Bool,
    requiresProvider: Bool,
    windowTargetSize: Int,
    windowFailed: Bool
) -> Bool {
    switch connectionState {
    case .connected, .reasserting:
        return rpcConnected && sdkTunnelStarted && requiresProvider &&
            windowTargetSize > 0 && !windowFailed
    case .invalid, .disconnected, .connecting, .disconnecting:
        return false
    }
}

/// Returns when a live status change deserves a health audit. Transitional
/// states get time to settle; a fully disconnected desired tunnel is repaired
/// immediately. A deliberate stop is also enforced if an active profile
/// remains behind.
func vpnTunnelHealthAuditDelay(
    shouldRun: Bool,
    reconcileInFlight: Bool,
    connectionState: VPNTunnelConnectionState,
    isHealthy: Bool,
    settings: VPNManagerSettings
) -> TimeInterval? {
    guard !reconcileInFlight else {
        return nil
    }
    if !shouldRun {
        return vpnTunnelConnectionIsStopped(connectionState)
            ? nil
            : settings.disconnectedAuditDelay
    }
    guard !isHealthy else {
        return nil
    }
    switch connectionState {
    case .invalid, .disconnected:
        return settings.disconnectedAuditDelay
    case .disconnecting:
        return settings.disconnectingAuditDelay
    case .connected:
        return settings.connectedBackendAuditDelay
    case .connecting, .reasserting:
        return settings.transitionalAuditDelay
    }
}

struct VPNTunnelConfigurationIdentity: Equatable {
    let rpcListenHostPort: String
    let rpcServerPem: String
    let rpcClientPem: String
    let networkSpaceJson: String
    // DeviceRemote and DeviceLocal must use the same instance ID: the SDK
    // rejects an RPC sync before applying state when they differ. Cold-launch
    // bootstrap recovers the provider-owned value before DeviceRemote exists;
    // normal adoption therefore requires exact equality.
    let instanceId: String
}

func vpnTunnelConfigurationMatchesForAdoption(
    installedIdentity: VPNTunnelConfigurationIdentity?,
    desiredIdentity: VPNTunnelConfigurationIdentity?
) -> Bool {
    guard vpnTunnelConfigurationMatchesForBootstrap(
        installedIdentity: installedIdentity,
        desiredIdentity: desiredIdentity
    ), let installedIdentity, let desiredIdentity else {
        return false
    }
    return installedIdentity.instanceId == desiredIdentity.instanceId
}

// A cold app process must discover the instance owned by an already-running
// packet tunnel before it constructs DeviceRemote. At that point an instance
// comparison is intentionally impossible; authenticate the candidate with the
// persisted RPC transport and network configuration, then adopt its instance.
func vpnTunnelConfigurationMatchesForBootstrap(
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
    // Connecting/reasserting profiles are adopted only long enough for the
    // caller's bounded health check. They are candidates, not healthy tunnels.
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

func vpnRunningTunnelBootstrapIdentity(
    candidates: [(
        connectionState: VPNTunnelConnectionState,
        identity: VPNTunnelConfigurationIdentity?
    )],
    desiredIdentity: VPNTunnelConfigurationIdentity?
) -> VPNTunnelConfigurationIdentity? {
    var selectedIdentity: VPNTunnelConfigurationIdentity?
    var selectedPriority = 0
    for candidate in candidates {
        guard let priority = vpnTunnelAdoptionPriority(candidate.connectionState),
              priority > selectedPriority,
              vpnTunnelConfigurationMatchesForBootstrap(
                installedIdentity: candidate.identity,
                desiredIdentity: desiredIdentity
              ) else {
            continue
        }
        selectedIdentity = candidate.identity
        selectedPriority = priority
    }
    return selectedIdentity
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
    // Foregrounding is a health boundary, not merely another desired-state
    // notification. Bypass the desired-state cache so NetworkExtension's live
    // connection status and RPC/backend readiness are inspected.
    return .forceReconcile
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

func vpnProfileRemovalMayContinue(attempt: Int, limit: Int) -> Bool {
    attempt < limit
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
        timeout: TimeInterval,
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
    timeout: TimeInterval,
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
