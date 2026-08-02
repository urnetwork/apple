//
//  VPNManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/20.
//

import Foundation
import NetworkExtension
import URnetworkSdk
import Network
import Combine
#if os(iOS)
import BackgroundTasks
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

//enum TunnelRequestStatus {
//    case started
//    case stopped
//    case none
//}

let TunnelCheckTimeout: TimeInterval = 10
private let TunnelLogoutProviderMessage = Data("logout".utf8)
private let VPNStateBurstCoalesceDelay: TimeInterval = 0.020
private let TunnelHealthPollInterval: TimeInterval = 0.250

private struct VPNManagerOperationError: LocalizedError {
    let operation: String
    let underlyingError: Error

    var errorDescription: String? {
        "[VPNManager][\(operation)] \(underlyingError.localizedDescription)"
    }
}

private func makeVPNManagerError(_ description: String, code: Int = 0) -> NSError {
    NSError(
        domain: "VPNManager",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}

private final class VPNUpdateWaiter {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Result<Void, Error>, Never>

    init(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        continuation.resume(returning: result)
    }
}

@MainActor
class VPNManager: ObservableObject {
    
    var device: SdkDeviceRemote
    @Published private(set) var lastError: Error?
    
//    var tunnelRequestStatus: TunnelRequestStatus = .none
    
    private var routeLocalSub: SdkSubProtocol?
    
    private var deviceOfflineSub: SdkSubProtocol?
    
    private var deviceConnectSub: SdkSubProtocol?
    
//    var deviceRemoteSub: SdkSubProtocol?
    
    private var tunnelSub: SdkSubProtocol?
    
    private var deviceProvideSub: SdkSubProtocol?
    private var deviceProvidePausedSub: SdkSubProtocol?
    // SDK state listeners can arrive in a burst for one logical transition.
    // Keep their payloads locally and reconcile only the final "tunnel should
    // run" bit. A pause-only or connect<->provide handoff while the tunnel is
    // already required must not rewrite preferences or restart the extension.
    private var desiredState = VPNDesiredState()
    private var lastAppliedShouldRun: Bool?
    private var activeShouldRun: Bool?
    private var pendingShouldRun: Bool?
    private var pendingForce = false
    private var pendingIndex = 0
    private var pendingReset = false
    private var reconcileScheduled = false
    private var reconcileScheduleGeneration: UInt64 = 0
    private var reconcileInFlight = false
    private var reconcileWaiters: [((Error?) -> Void)] = []
    private var isClosed = false
    private var idleTimerDisabled = false

    // per-session rpc transport (client/server self-signed material + listen port)
    private var rpcRemoteChangeSub: SdkSubProtocol?
    private var rpcConnectTimeoutWork: DispatchWorkItem?
    private var currentRpcSession: RpcSession?
    private let rpcConnectTimeout: TimeInterval = 15

//    private var tunnelStarted: Bool = false
    private var tunnelInstance: Int = 0
    
    var contractStatusSub: SdkSubProtocol?
    
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "NetworkMonitor")
    
    
    init(device: SdkDeviceRemote) {
        print("[VPNManager]init")
        self.device = device
        self.desiredState = VPNDesiredState(
            provideEnabled: device.getProvideEnabled(),
            connectEnabled: device.getConnectEnabled(),
            routeLocal: device.getRouteLocal(),
            providePaused: device.getProvidePaused()
        )
        
        self.monitor.start(queue: queue)

        self.routeLocalSub = device.add(RouteLocalChangeListener { [weak self] routeLocal in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desiredState.routeLocal = routeLocal
                self.requestVpnServiceUpdate()
            }
        })
             
        self.deviceOfflineSub = device.add(OfflineChangeListener { [weak self] _, _ in
            DispatchQueue.main.async {
                // Offline changes do not alter whether the packet tunnel is
                // needed. Reconcile cached state so a concurrent real state
                // change is folded into the same main-queue turn.
                self?.requestVpnServiceUpdate()
            }
        })
        
        self.deviceConnectSub = device.add(ConnectChangeListener { [weak self] connectEnabled in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desiredState.connectEnabled = connectEnabled
                self.requestVpnServiceUpdate()
            }
        })
        
//        self.tunnelSub = device.add(TunnelChangeListener { [weak self] _ in
//            DispatchQueue.main.async {
//                self?.updateTunnel()
//            }
//        })
        
//        self.contractStatusSub = device.add(ContractStatusChangeListener { [weak self] _ in
//            DispatchQueue.main.async {
//                self?.updateContractStatus()
//            }
//        })
        
        self.deviceProvidePausedSub = device.add(ProvidePausedChangeListener { [weak self] providePaused in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desiredState.providePaused = providePaused
                self.requestVpnServiceUpdate()
            }
        })
        
        self.deviceProvideSub = device.add(ProvideChangeListener { [weak self] provideEnabled in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desiredState.provideEnabled = provideEnabled
                self.requestVpnServiceUpdate()
            }
        })
        
//        updateTunnel()
//        updateContractStatus()
        
        // Force one initial application: a newly created manager also installs
        // the per-session RPC material, even if an old tunnel is still up.
        requestVpnServiceUpdate(force: true, coalesceBurst: false)
    }
    
    #if os(iOS)
    func scheduleBackgroundUpdate() {
       let request = BGAppRefreshTaskRequest(identifier: "network.ur.update-tunnel")
       request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

       do {
          try BGTaskScheduler.shared.submit(request)
       } catch {
          print("Could not schedule background update: \(error)")
       }
    }
    
    func handleBackgroundUpdate(task: BGTask) {
        task.setTaskCompleted(success: true)
    }
    #endif
    
    
    
//    deinit {
//        print("VPN Manager deinit")
//        
//        self.close()
//    }
    
    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        self.tunnelInstance += 1
        self.monitor.cancel()
        self.setIdleTimerDisabled(false)

        reconcileScheduled = false
        reconcileScheduleGeneration &+= 1
        reconcileInFlight = false
        activeShouldRun = nil
        pendingShouldRun = nil
        pendingForce = false
        pendingIndex = 0
        pendingReset = false
        let waiters = reconcileWaiters
        reconcileWaiters = []
        let cancellationError = makeVPNManagerError("VPN manager closed", code: 7)
        for waiter in waiters {
            waiter(cancellationError)
        }
        
        self.routeLocalSub?.close()
        self.routeLocalSub = nil
        
        self.deviceOfflineSub?.close()
        self.deviceOfflineSub = nil
        
        self.deviceConnectSub?.close()
        self.deviceConnectSub = nil
        
//        self.deviceRemoteSub?.close()
//        self.deviceRemoteSub = nil
        
        self.tunnelSub?.close()
        self.tunnelSub = nil
        
        self.contractStatusSub?.close()
        self.contractStatusSub = nil
        
        self.deviceProvideSub?.close()
        self.deviceProvideSub = nil
        
        self.deviceProvidePausedSub?.close()
        self.deviceProvidePausedSub = nil

        self.rpcRemoteChangeSub?.close()
        self.rpcRemoteChangeSub = nil
        self.rpcConnectTimeoutWork?.cancel()
        self.rpcConnectTimeoutWork = nil
    }
    
    
    private func getPasswordReference() -> Data? {
        // Retrieve the password reference from the keychain
        return nil
    }
    
    
//    private func updateTunnel() {
//        let tunnelStarted = self.device.getTunnelStarted()
//        print("[VPNManager][tunnel]started=\(tunnelStarted)")
//    }
    
//    private func updateContractStatus() {
//        if let contractStatus = self.device.getContractStatus() {
//            print("[VPNManager][contract]insufficent=\(contractStatus.insufficientBalance) nopermission=\(contractStatus.noPermission) premium=\(contractStatus.premium)")
//        } else {
//            print("[VPNManager][contract]no contract status")
//        }
//    }
    
    func updateVpnService() {
        refreshDesiredStateFromDevice()
        requestVpnServiceUpdate(coalesceBurst: false)
    }

    func updateVpnServiceAndWait(timeout: TimeInterval = 30) async -> Result<Void, Error> {
        // the tunnel is the packet router: it must run whenever the device is
        // connected, providing (any mode — including Network, which relays for
        // same-network peers), or routing remotely
        refreshDesiredStateFromDevice()
        let expectedTunnelStarted = desiredState.shouldRun

        let updateResult: Result<Void, Error> = await withCheckedContinuation { continuation in
            let waiter = VPNUpdateWaiter(continuation)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                waiter.resume(.failure(makeVPNManagerError("Timed out updating VPN service", code: 5)))
            }

            requestVpnServiceUpdate(coalesceBurst: false) { error in
                if let error {
                    waiter.resume(.failure(error))
                } else {
                    waiter.resume(.success(()))
                }
            }
        }

        if case .failure = updateResult {
            return updateResult
        }

        return await waitForTunnelState(started: expectedTunnelStarted, timeout: timeout)
    }

    private func waitForTunnelState(started: Bool, timeout: TimeInterval) async -> Result<Void, Error> {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if device.getTunnelStarted() == started {
                return .success(())
            }

            if let lastError {
                return .failure(lastError)
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let lastError {
            return .failure(lastError)
        }

        let operation = started ? "start" : "stop"
        return .failure(makeVPNManagerError("Timed out waiting for VPN tunnel to \(operation)", code: 6))
    }

    private func refreshDesiredStateFromDevice() {
        desiredState = VPNDesiredState(
            provideEnabled: device.getProvideEnabled(),
            connectEnabled: device.getConnectEnabled(),
            routeLocal: device.getRouteLocal(),
            providePaused: device.getProvidePaused()
        )
    }

    func applicationDidBecomeActive() {
        let action = vpnForegroundRetryAction(
            isClosed: isClosed,
            reconcileInFlight: reconcileInFlight,
            hasError: lastError != nil
        )
        guard action != .none else {
            return
        }

        #if DEBUG
        print("[VPNManager] application active retry=\(action)")
        #endif

        // Scene activation is the safe boundary after iOS authorization UI.
        // Queue a failed retry even if the timed-out generation is completing
        // this same main-queue turn; serialized reconciliation prevents overlap.
        refreshDesiredStateFromDevice()
        requestVpnServiceUpdate(
            force: action == .forceReconcile,
            coalesceBurst: false
        )
    }

    private func requestVpnServiceUpdate(
        force: Bool = false,
        coalesceBurst: Bool = true,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard !isClosed else {
            completion?(makeVPNManagerError("VPN manager closed", code: 7))
            return
        }

        // This is the only side effect of providePaused. It does not require a
        // NetworkExtension preferences transaction or an extension restart.
        setIdleTimerDisabled(desiredState.shouldRun && !desiredState.providePaused)

        if let completion {
            reconcileWaiters.append(completion)
        }

        let shouldRun = desiredState.shouldRun
        if reconcileInFlight, activeShouldRun == shouldRun, !force {
            // A listener echoed the state already being applied. If an opposite
            // state was queued earlier in this same burst, the newest state wins.
            if !pendingForce {
                pendingShouldRun = nil
                pendingIndex = 0
                pendingReset = false
            }
            return
        }

        let replacesDifferentState = pendingShouldRun != nil && pendingShouldRun != shouldRun
        if !pendingForce || replacesDifferentState || force {
            pendingIndex = 0
            pendingReset = false
        }
        pendingShouldRun = shouldRun
        pendingForce = pendingForce || force
        scheduleVpnReconcile(
            delay: coalesceBurst ? VPNStateBurstCoalesceDelay : 0
        )
    }

    private func requestVpnRecovery(
        shouldRun: Bool,
        index: Int,
        reset: Bool
    ) {
        guard !isClosed else {
            return
        }
        guard desiredState.shouldRun == shouldRun else {
            // State changed while the health check was pending. The latest
            // desired state wins over recovery of the obsolete one.
            requestVpnServiceUpdate(coalesceBurst: false)
            return
        }

        pendingShouldRun = shouldRun
        pendingForce = true
        pendingIndex = index
        pendingReset = reset
        scheduleVpnReconcile()
    }

    private func scheduleVpnReconcile(delay: TimeInterval = 0) {
        guard !reconcileInFlight, !isClosed else {
            return
        }

        if reconcileScheduled {
            // A user-initiated update can expedite a listener debounce. A
            // second listener update simply replaces the desired state and
            // shares the already scheduled deadline.
            guard delay == 0 else {
                return
            }
        }

        reconcileScheduleGeneration &+= 1
        let generation = reconcileScheduleGeneration
        reconcileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == self.reconcileScheduleGeneration else {
                return
            }
            self.runNextVpnReconcile()
        }
    }

    private func runNextVpnReconcile() {
        reconcileScheduled = false
        guard !isClosed, !reconcileInFlight, let shouldRun = pendingShouldRun else {
            return
        }

        let force = pendingForce
        let index = pendingIndex
        let reset = pendingReset
        pendingShouldRun = nil
        pendingForce = false
        pendingIndex = 0
        pendingReset = false

        if !force, lastAppliedShouldRun == shouldRun {
            finishVpnReconcile(error: nil)
            return
        }

        reconcileInFlight = true
        activeShouldRun = shouldRun

        #if os(iOS)
        scheduleBackgroundUpdate()
        #endif

        updateVpnServiceWithReset(index: index, reset: reset, shouldRun: shouldRun) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.isClosed else {
                    return
                }
                if error == nil {
                    self.lastAppliedShouldRun = shouldRun
                } else {
                    // A failed forced recovery must not leave the previous
                    // value looking applied; foreground/network changes need
                    // to be able to retry it.
                    self.lastAppliedShouldRun = nil
                }
                self.reconcileInFlight = false
                self.activeShouldRun = nil

                if self.pendingShouldRun != nil {
                    // An error for an obsolete state must not fail a waiter for
                    // the newer state; apply the latest request first.
                    self.scheduleVpnReconcile()
                } else {
                    self.finishVpnReconcile(error: error)
                }
            }
        }
    }
    
    private func finishVpnReconcile(error: Error?) {
        let waiters = reconcileWaiters
        reconcileWaiters = []
        for waiter in waiters {
            waiter(error)
        }
    }

    private func updateVpnServiceWithReset(
        index: Int,
        reset: Bool,
        shouldRun: Bool,
        completion: ((Error?) -> Void)? = nil
    ) {

        #if DEBUG
        print("[VPNManager] reconcile shouldRun=\(shouldRun) reset=\(reset) index=\(index)")
        #endif

        if shouldRun {
            #if DEBUG
            print("[VPNManager]start")
            #endif

            self.startVpnTunnel(
                index: index,
                reset: reset,
                shouldRun: shouldRun,
                completion: completion
            )
            
        } else {
            #if DEBUG
            print("[VPNManager]stop")
            #endif

            self.stopVpnTunnel(
                index: index,
                reset: reset,
                shouldRun: shouldRun,
                completion: completion
            )
        }
    }
    
    private func setIdleTimerDisabled(_ disabled: Bool) {
        guard idleTimerDisabled != disabled else {
            return
        }
        idleTimerDisabled = disabled

        // see https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #elseif canImport(AppKit)
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = !disabled
        #endif
    }

    private func loadAllVpnManagers(
        operation: String,
        completion: @escaping (Result<[NETunnelProviderManager], Error>) -> Void
    ) {
        performVPNOperation(operation: operation) { resolve in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(managers ?? []))
                }
            }
        } completion: { result in
            completion(result)
        }
    }

    private func saveVpnManager(
        _ manager: NETunnelProviderManager,
        operation: String,
        lateCompletion: ((Error?) -> Void)? = nil,
        completion: @escaping (Error?) -> Void
    ) {
        performVPNOperation(
            operation: operation,
            lateCompletion: { result in
                if case .failure(let error) = result {
                    lateCompletion?(error)
                } else {
                    lateCompletion?(nil)
                }
            }
        ) { resolve in
            manager.saveToPreferences { error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(()))
                }
            }
        } completion: { (result: Result<Void, Error>) in
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
            }
        }
    }

    private func reconcileAfterLatePreferenceWrite(
        operation: String,
        error: Error?
    ) {
        guard vpnLatePreferenceWriteNeedsReconcile(
            isClosed: isClosed,
            error: error
        ) else {
            if let error {
                print(
                    "[VPNManager][\(operation)] late preference callback failed: \(error.localizedDescription)"
                )
            }
            return
        }

        // The authorization dialog can outlive the operation deadline. The
        // system still commits a successful late save, but the timed-out
        // reconcile has already returned. Re-apply the latest desired state;
        // this also corrects a stale late start after the user switched off.
        print("[VPNManager][\(operation)] late preference save completed; reconciling current state")
        requestVpnServiceUpdate(force: true, coalesceBurst: false)
    }

    private func loadVpnManager(
        _ manager: NETunnelProviderManager,
        operation: String,
        completion: @escaping (Error?) -> Void
    ) {
        performVPNOperation(operation: operation) { resolve in
            manager.loadFromPreferences { error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(()))
                }
            }
        } completion: { (result: Result<Void, Error>) in
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
            }
        }
    }

    private func removeVpnManager(
        _ manager: NETunnelProviderManager,
        operation: String,
        completion: @escaping (Error?) -> Void
    ) {
        performVPNOperation(operation: operation) { resolve in
            manager.removeFromPreferences { error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(()))
                }
            }
        } completion: { (result: Result<Void, Error>) in
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
            }
        }
    }

    private func finishAcceptedTunnelTransition(
        expectedStarted: Bool,
        operation: String,
        device: SdkDeviceRemote,
        index: Int,
        reset: Bool,
        shouldRun: Bool,
        managerCount: Int,
        tunnelInstance: Int,
        completion: ((Error?) -> Void)?
    ) {
        clearVpnError()
        let recoveryAction = vpnTunnelRecoveryAction(
            index: index,
            reset: reset,
            managerCount: managerCount
        )

        if recoveryAction == .reportFailure {
            waitForTerminalTunnelHealth(
                expectedStarted: expectedStarted,
                operation: operation,
                device: device,
                shouldRun: shouldRun,
                tunnelInstance: tunnelInstance,
                deadline: Date().addingTimeInterval(TunnelCheckTimeout),
                completion: completion
            )
            return
        }

        // The first attempt remains fast: return as soon as NetworkExtension
        // accepts it, then independently validate actual SDK tunnel health.
        // A reset's final attempt is handled above and cannot silently succeed.
        completion?(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + TunnelCheckTimeout) { [weak self] in
            guard let self,
                  tunnelInstance == self.tunnelInstance else {
                return
            }
            guard self.desiredState.shouldRun == shouldRun else {
                self.requestVpnServiceUpdate(coalesceBurst: false)
                return
            }
            guard device.getTunnelStarted() != expectedStarted else {
                return
            }

            switch recoveryAction {
            case .restartCurrentProfileInPlace:
                self.requestVpnRecovery(
                    shouldRun: shouldRun,
                    index: index,
                    reset: true
                )
            case .tryNextProfile(let nextIndex):
                self.requestVpnRecovery(
                    shouldRun: shouldRun,
                    index: nextIndex,
                    reset: false
                )
            case .reportFailure:
                break
            }
        }
    }

    private func waitForTerminalTunnelHealth(
        expectedStarted: Bool,
        operation: String,
        device: SdkDeviceRemote,
        shouldRun: Bool,
        tunnelInstance: Int,
        deadline: Date,
        completion: ((Error?) -> Void)?
    ) {
        guard tunnelInstance == self.tunnelInstance else {
            completion?(makeVPNManagerError("VPN operation superseded", code: 10))
            return
        }
        guard desiredState.shouldRun == shouldRun else {
            // Finish the obsolete transition so the queued desired state can
            // run immediately.
            completion?(nil)
            return
        }
        if device.getTunnelStarted() == expectedStarted {
            clearVpnError()
            completion?(nil)
            return
        }
        if Date() >= deadline {
            let expectedState = expectedStarted ? "start" : "stop"
            let error = makeVPNManagerError(
                "VPN tunnel failed to \(expectedState) after profile reset",
                code: 11
            )
            completion?(
                reportVpnError(
                    error,
                    operation: operation,
                    tunnelInstance: tunnelInstance
                ) ?? error
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + TunnelHealthPollInterval) { [weak self] in
            self?.waitForTerminalTunnelHealth(
                expectedStarted: expectedStarted,
                operation: operation,
                device: device,
                shouldRun: shouldRun,
                tunnelInstance: tunnelInstance,
                deadline: deadline,
                completion: completion
            )
        }
    }

    private func tunnelConnectionState(_ status: NEVPNStatus) -> VPNTunnelConnectionState {
        switch status {
        case .invalid:
            return .invalid
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .reasserting:
            return .reasserting
        case .disconnecting:
            return .disconnecting
        @unknown default:
            return .invalid
        }
    }

    private func prepareTunnelManagerForConfiguration(
        _ tunnelManager: NETunnelProviderManager,
        profileExists: Bool,
        tunnelInstance: Int,
        completion: @escaping (Error?) -> Void
    ) {
        let connectionState = tunnelConnectionState(
            tunnelManager.connection.status
        )
        guard vpnTunnelNeedsStopBeforeConfiguration(
            profileExists: profileExists,
            connectionState: connectionState
        ) else {
            completion(nil)
            return
        }

        tunnelManager.connection.stopVPNTunnel()
        waitForTunnelManagerToStop(
            tunnelManager,
            tunnelInstance: tunnelInstance,
            deadline: Date().addingTimeInterval(TunnelCheckTimeout),
            completion: completion
        )
    }

    private func waitForTunnelManagerToStop(
        _ tunnelManager: NETunnelProviderManager,
        tunnelInstance: Int,
        deadline: Date,
        completion: @escaping (Error?) -> Void
    ) {
        guard tunnelInstance == self.tunnelInstance else {
            completion(makeVPNManagerError("VPN operation superseded", code: 10))
            return
        }
        let connectionState = tunnelConnectionState(
            tunnelManager.connection.status
        )
        if vpnTunnelConnectionIsStopped(connectionState) {
            completion(nil)
            return
        }
        if Date() >= deadline {
            completion(
                makeVPNManagerError(
                    "Timed out waiting for the existing VPN profile to stop before restart",
                    code: 16
                )
            )
            return
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + TunnelHealthPollInterval
        ) { [weak self] in
            self?.waitForTunnelManagerToStop(
                tunnelManager,
                tunnelInstance: tunnelInstance,
                deadline: deadline,
                completion: completion
            )
        }
    }

    private func installedTunnelIdentity(
        _ manager: NETunnelProviderManager
    ) -> VPNTunnelConfigurationIdentity? {
        guard let tunnelProtocol =
                manager.protocolConfiguration as? NETunnelProviderProtocol,
              let configuration = tunnelProtocol.providerConfiguration,
              let rpcListenHostPort =
                configuration["rpc_listen_hostport"] as? String,
              let rpcServerPem = configuration["rpc_server_pem"] as? String,
              let rpcClientPem = configuration["rpc_client_pem"] as? String,
              let networkSpaceJson = configuration["network_space"] as? String,
              let instanceId = configuration["instance_id"] as? String else {
            return nil
        }
        return VPNTunnelConfigurationIdentity(
            rpcListenHostPort: rpcListenHostPort,
            rpcServerPem: rpcServerPem,
            rpcClientPem: rpcClientPem,
            networkSpaceJson: networkSpaceJson,
            instanceId: instanceId
        )
    }

    private func desiredTunnelIdentity(
        device: SdkDeviceRemote,
        rpcSession: RpcSession
    ) -> VPNTunnelConfigurationIdentity? {
        guard let networkSpace = device.getNetworkSpace() else {
            return nil
        }
        var error: NSError?
        let networkSpaceJson = networkSpace.toJson(&error)
        guard error == nil, !networkSpaceJson.isEmpty else {
            return nil
        }
        let instanceId = device.getInstanceId()?.string() ?? ""
        return VPNTunnelConfigurationIdentity(
            rpcListenHostPort: rpcSession.hostPort,
            rpcServerPem: rpcSession.serverPem,
            rpcClientPem: rpcSession.clientCertPem,
            networkSpaceJson: networkSpaceJson,
            instanceId: instanceId
        )
    }

    private func tunnelIdentityMatchSummary(
        installed: VPNTunnelConfigurationIdentity?,
        desired: VPNTunnelConfigurationIdentity?
    ) -> String {
        guard let installed else {
            return "installed=missing"
        }
        guard let desired else {
            return "desired=missing"
        }
        let rpcMatches =
            installed.rpcListenHostPort == desired.rpcListenHostPort &&
            installed.rpcServerPem == desired.rpcServerPem &&
            installed.rpcClientPem == desired.rpcClientPem
        return "rpc=\(rpcMatches) network=\(installed.networkSpaceJson == desired.networkSpaceJson) instance=\(installed.instanceId == desired.instanceId)"
    }

    // prepareRpcSession returns the rpc session to use for this start: the
    // in-flight session if one is pending (so internal retries are stable), the
    // last known good session if present, or fresh mTLS material on a random
    // listen port.
    private func prepareRpcSession() -> RpcSession? {
        if let session = self.currentRpcSession {
            return session
        }
        if let session = RpcSessionStore.load() {
            self.currentRpcSession = session
            return session
        }
        var err: NSError?
        guard let keyMaterial = SdkGenerateDeviceRpcKeyMaterial(&err), err == nil else {
            return nil
        }
        // the getters return non-optional strings (Go string); validate non-empty
        let clientPem = keyMaterial.getClientPem()
        let clientCertPem = keyMaterial.getClientCertPem()
        let serverPem = keyMaterial.getServerPem()
        let serverCertPem = keyMaterial.getServerCertPem()
        guard !clientPem.isEmpty, !clientCertPem.isEmpty, !serverPem.isEmpty, !serverCertPem.isEmpty else {
            return nil
        }
        let session = RpcSession(
            clientPem: clientPem,
            clientCertPem: clientCertPem,
            serverPem: serverPem,
            serverCertPem: serverCertPem,
            host: "127.0.0.1",
            port: Int.random(in: 12000...12100)
        )
        self.currentRpcSession = session
        return session
    }

    // applyRpcSession resets the app device's rpc transport to dial the
    // extension's listener with this session, then arms an observer: on a
    // successful rpc connection the session is persisted as last known good.
    // Only fresh (never-connected) material is put on a connect deadline; a
    // session that already connected before is kept and reused, so repeated
    // restarts (e.g. switching locations) never discard known-good material.
    private func applyRpcSession(_ session: RpcSession, device: SdkDeviceRemote, tunnelInstance: Int) {
        do {
            try device.setRpcServer(session.clientPem, serverCertPem: session.serverCertPem, hostPort: session.hostPort)
        } catch {
            print("[VPNManager]setRpcServer failed: \(error.localizedDescription)")
        }

        self.rpcRemoteChangeSub?.close()
        self.rpcConnectTimeoutWork?.cancel()

        self.rpcRemoteChangeSub = device.add(RemoteChangeListener { [weak self] remoteConnected in
            DispatchQueue.main.async {
                guard let self = self, tunnelInstance == self.tunnelInstance else { return }
                guard remoteConnected else { return }
                // this material connected; persist it as last-known-good and stop the timeout
                self.rpcConnectTimeoutWork?.cancel()
                self.rpcConnectTimeoutWork = nil
                RpcSessionStore.save(session)
            }
        })

        // Only fresh, never-connected material is put on a connect deadline. If a
        // session is already the persisted last-known-good it has connected
        // before, so keep reusing it — a transient timeout while the tunnel keeps
        // restarting (e.g. switching locations repeatedly, which calls
        // updateVpnService over and over) must not discard good key material or
        // force a new port on the next start.
        guard RpcSessionStore.load() == nil else { return }

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self, tunnelInstance == self.tunnelInstance else { return }
            // the rpc channel never came up with this fresh material; drop it so
            // the next start generates new material on a new port
            self.currentRpcSession = nil
        }
        self.rpcConnectTimeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + self.rpcConnectTimeout, execute: timeoutWork)
    }

    private func clearVpnError() {
        lastError = nil
    }

    @discardableResult
    private func reportVpnError(_ error: Error, operation: String, tunnelInstance: Int) -> Error? {
        guard tunnelInstance == self.tunnelInstance else { return nil }

        let wrappedError = VPNManagerOperationError(operation: operation, underlyingError: error)
        lastError = wrappedError
        setIdleTimerDisabled(false)
        print(wrappedError.localizedDescription)
        return wrappedError
    }

    private func failVpnUpdate(
        _ error: Error,
        operation: String,
        tunnelInstance: Int,
        completion: ((Error?) -> Void)?
    ) {
        completion?(reportVpnError(error, operation: operation, tunnelInstance: tunnelInstance) ?? error)
    }

    private func retryStartOrReport(
        _ error: Error,
        operation: String,
        index: Int,
        reset: Bool,
        shouldRun: Bool,
        managerCount: Int,
        tunnelInstance: Int,
        completion: ((Error?) -> Void)?
    ) {
        guard tunnelInstance == self.tunnelInstance else { return }

        guard vpnOperationMayRetryImmediately(after: error) else {
            completion?(
                reportVpnError(
                    error,
                    operation: operation,
                    tunnelInstance: tunnelInstance
                ) ?? error
            )
            return
        }

        if !reset {
            print("[VPNManager][\(operation)] \(error.localizedDescription); retrying after reset")
            updateVpnServiceWithReset(
                index: index,
                reset: true,
                shouldRun: shouldRun,
                completion: completion
            )
        } else if index + 1 < managerCount {
            print("[VPNManager][\(operation)] \(error.localizedDescription); trying next VPN profile")
            updateVpnServiceWithReset(
                index: index + 1,
                reset: false,
                shouldRun: shouldRun,
                completion: completion
            )
        } else {
            completion?(reportVpnError(error, operation: operation, tunnelInstance: tunnelInstance) ?? error)
        }
    }

    private func retryStopOrReport(
        _ error: Error,
        operation: String,
        index: Int,
        reset: Bool,
        shouldRun: Bool,
        managerCount: Int,
        tunnelInstance: Int,
        completion: ((Error?) -> Void)?
    ) {
        guard tunnelInstance == self.tunnelInstance else { return }

        guard vpnOperationMayRetryImmediately(after: error) else {
            completion?(
                reportVpnError(
                    error,
                    operation: operation,
                    tunnelInstance: tunnelInstance
                ) ?? error
            )
            return
        }

        if !reset {
            print("[VPNManager][\(operation)] \(error.localizedDescription); retrying after reset")
            updateVpnServiceWithReset(
                index: index,
                reset: true,
                shouldRun: shouldRun,
                completion: completion
            )
        } else if index + 1 < managerCount {
            print("[VPNManager][\(operation)] \(error.localizedDescription); trying next VPN profile")
            updateVpnServiceWithReset(
                index: index + 1,
                reset: false,
                shouldRun: shouldRun,
                completion: completion
            )
        } else {
            completion?(reportVpnError(error, operation: operation, tunnelInstance: tunnelInstance) ?? error)
        }
    }
    
    
    private func startVpnTunnel(
        index: Int,
        reset: Bool,
        shouldRun: Bool,
        completion: ((Error?) -> Void)? = nil
    ) {
//        if tunnelStarted {
//            return
//        }
//        tunnelStarted = true
        self.tunnelInstance += 1
        let tunnelInstance = self.tunnelInstance
        
        // Load all configurations first. Every preferences callback is
        // deadline-bounded so authorization UI or a wedged system daemon
        // cannot pin the serialized reconciler forever.
        loadAllVpnManagers(operation: "start.loadAllFromPreferences") { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, tunnelInstance == self.tunnelInstance else { return }
                guard case .success(let managers) = result else {
                    let error: Error
                    if case .failure(let resultError) = result {
                        error = resultError
                    } else {
                        error = makeVPNManagerError("Failed to load VPN profiles", code: 12)
                    }
                    self.failVpnUpdate(
                        error,
                        operation: "start.loadAllFromPreferences",
                        tunnelInstance: tunnelInstance,
                        completion: completion
                    )
                    return
                }

                let device = self.device

                let n = managers.count
                let rpcSession = self.prepareRpcSession()
                let desiredIdentity = rpcSession.flatMap {
                    self.desiredTunnelIdentity(device: device, rpcSession: $0)
                }
                let adoptionCandidates = managers.map {
                    (
                        connectionState: self.tunnelConnectionState(
                            $0.connection.status
                        ),
                        identity: self.installedTunnelIdentity($0)
                    )
                }
                if let adoptionIndex = vpnRunningTunnelAdoptionIndex(
                    reset: reset,
                    candidates: adoptionCandidates,
                    desiredIdentity: desiredIdentity
                ),
                   let rpcSession {
                    #if DEBUG
                    print("[VPNManager]adopt running tunnel profile=\(adoptionIndex) count=\(n)")
                    #endif
                    self.applyRpcSession(
                        rpcSession,
                        device: device,
                        tunnelInstance: tunnelInstance
                    )
                    device.sync()
                    self.finishAcceptedTunnelTransition(
                        expectedStarted: true,
                        operation: "start.adopt.health",
                        device: device,
                        index: adoptionIndex,
                        reset: reset,
                        shouldRun: shouldRun,
                        managerCount: n,
                        tunnelInstance: tunnelInstance,
                        completion: completion
                    )
                    return
                }

                #if DEBUG
                let candidateSummary = managers.indices.map {
                    let state = adoptionCandidates[$0].connectionState
                    let identitySummary = self.tunnelIdentityMatchSummary(
                        installed: adoptionCandidates[$0].identity,
                        desired: desiredIdentity
                    )
                    return "\($0):\(state):\(identitySummary)"
                }.joined(separator: ",")
                print("[VPNManager]no running tunnel adoption reset=\(reset) profiles=\(n) [\(candidateSummary)]")
                #endif

                var tunnelManager: NETunnelProviderManager
                tunnelManager = index < n ? managers[index] : NETunnelProviderManager()

                let startTunnel = {
                    guard tunnelInstance == self.tunnelInstance else { return }

                    guard let networkSpace = device.getNetworkSpace() else {
                        self.failVpnUpdate(
                            makeVPNManagerError("Missing network space", code: 1),
                            operation: "start.buildProviderConfiguration",
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                        return
                    }

                    var err: NSError?
                    let networkSpaceJson = networkSpace.toJson(&err)
                    if let err {
                        self.failVpnUpdate(
                            err,
                            operation: "start.networkSpaceToJson",
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                        return
                    }
                    guard !networkSpaceJson.isEmpty else {
                        self.failVpnUpdate(
                            makeVPNManagerError("Network space JSON is empty", code: 2),
                            operation: "start.buildProviderConfiguration",
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                        return
                    }
                    guard let byJwt = device.getApi()?.getByJwt(), !byJwt.isEmpty else {
                        self.failVpnUpdate(
                            makeVPNManagerError("Missing by_jwt", code: 3),
                            operation: "start.buildProviderConfiguration",
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                        return
                    }
                    guard let instanceId = device.getInstanceId()?.string(), !instanceId.isEmpty else {
                        self.failVpnUpdate(
                            makeVPNManagerError("Missing instance_id", code: 4),
                            operation: "start.buildProviderConfiguration",
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                        return
                    }

                    let tunnelProtocol = NETunnelProviderProtocol()
                    tunnelProtocol.serverAddress = networkSpace.getHostName()
                    tunnelProtocol.providerBundleIdentifier = "network.ur.extension"
                    tunnelProtocol.disconnectOnSleep = false
                    tunnelProtocol.excludeLocalNetworks = true
                    tunnelProtocol.excludeCellularServices = true
                    tunnelProtocol.excludeAPNs = true
                    if #available(iOS 17.4, macOS 14.4, *) {
                        tunnelProtocol.excludeDeviceCommunication = true
                    }

                    guard let rpcSession = rpcSession ?? self.prepareRpcSession() else {
                        self.failVpnUpdate(
                            makeVPNManagerError("Failed to generate rpc key material", code: 9),
                            operation: "start.buildProviderConfiguration",
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                        return
                    }

                    tunnelProtocol.providerConfiguration = [
                        "by_jwt": byJwt,
                        // self-signed server cert + private key the extension presents
                        "rpc_server_pem": rpcSession.serverPem,
                        // client cert (public only) the extension pins for mTLS;
                        // the client private key stays in the app
                        "rpc_client_pem": rpcSession.clientCertPem,
                        // host:port the extension listens on and the app dials
                        "rpc_listen_hostport": rpcSession.hostPort,
                        "network_space": networkSpaceJson,
                        "instance_id": instanceId,
                    ]

                    tunnelManager.protocolConfiguration = tunnelProtocol

                    tunnelManager.localizedDescription = "URnetwork [\(networkSpace.getHostName()) \(networkSpace.getEnvName())]"
                    tunnelManager.isEnabled = true
                    tunnelManager.isOnDemandEnabled = false
                    let connectRule = NEOnDemandRuleConnect()
                    connectRule.interfaceTypeMatch = NEOnDemandRuleInterfaceType.any
                    tunnelManager.onDemandRules = [connectRule]

                    self.saveVpnManager(
                        tunnelManager,
                        operation: "start.saveToPreferences",
                        lateCompletion: { [weak self] error in
                            DispatchQueue.main.async {
                                self?.reconcileAfterLatePreferenceWrite(
                                    operation: "start.saveToPreferences",
                                    error: error
                                )
                            }
                        }
                    ) { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self = self, tunnelInstance == self.tunnelInstance else { return }
                            if let error {
                                self.retryStartOrReport(
                                    error,
                                    operation: "start.saveToPreferences",
                                    index: index,
                                    reset: reset,
                                    shouldRun: shouldRun,
                                    managerCount: n,
                                    tunnelInstance: tunnelInstance,
                                    completion: completion
                                )
                                return
                            }

                            self.loadVpnManager(
                                tunnelManager,
                                operation: "start.loadFromPreferences"
                            ) { [weak self] error in
                                DispatchQueue.main.async {
                                    guard let self = self, tunnelInstance == self.tunnelInstance else { return }
                                    if let error {
                                        self.retryStartOrReport(
                                            error,
                                            operation: "start.loadFromPreferences",
                                            index: index,
                                            reset: reset,
                                            shouldRun: shouldRun,
                                            managerCount: n,
                                            tunnelInstance: tunnelInstance,
                                            completion: completion
                                        )
                                        return
                                    }

                                    do {
                                        try tunnelManager.connection.startVPNTunnel()
                                        self.clearVpnError()
                                        // point the app's rpc transport at the extension's listener
                                        // (pinning the matching client cert) and watch for a
                                        // successful connection
                                        self.applyRpcSession(rpcSession, device: device, tunnelInstance: tunnelInstance)
                                        device.sync()
                                        self.finishAcceptedTunnelTransition(
                                            expectedStarted: true,
                                            operation: "start.health",
                                            device: device,
                                            index: index,
                                            reset: reset,
                                            shouldRun: shouldRun,
                                            managerCount: n,
                                            tunnelInstance: tunnelInstance,
                                            completion: completion
                                        )
                                    } catch {
                                        self.retryStartOrReport(
                                            error,
                                            operation: "start.startVPNTunnel",
                                            index: index,
                                            reset: reset,
                                            shouldRun: shouldRun,
                                            managerCount: n,
                                            tunnelInstance: tunnelInstance,
                                            completion: completion
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                self.prepareTunnelManagerForConfiguration(
                    tunnelManager,
                    profileExists: index < n,
                    tunnelInstance: tunnelInstance
                ) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self = self,
                              tunnelInstance == self.tunnelInstance else {
                            return
                        }
                        if let error {
                            self.retryStartOrReport(
                                error,
                                operation: "start.prepareExistingProfile",
                                index: index,
                                reset: reset,
                                shouldRun: shouldRun,
                                managerCount: n,
                                tunnelInstance: tunnelInstance,
                                completion: completion
                            )
                            return
                        }
                        startTunnel()
                    }
                }
            }
        }
    }

    private func stopVpnTunnel(
        index: Int,
        reset: Bool,
        shouldRun: Bool,
        completion: ((Error?) -> Void)? = nil
    ) {
        self.tunnelInstance += 1
        let tunnelInstance = self.tunnelInstance

        loadAllVpnManagers(operation: "stop.loadAllFromPreferences") { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, tunnelInstance == self.tunnelInstance else { return }
                guard case .success(let managers) = result else {
                    let error: Error
                    if case .failure(let resultError) = result {
                        error = resultError
                    } else {
                        error = makeVPNManagerError("Failed to load VPN profiles", code: 12)
                    }
                    self.failVpnUpdate(
                        error,
                        operation: "stop.loadAllFromPreferences",
                        tunnelInstance: tunnelInstance,
                        completion: completion
                    )
                    return
                }

                let device = self.device

                guard index < managers.count else {
                    self.clearVpnError()
                    completion?(nil)
                    return
                }
                let n = managers.count
                let tunnelManager = managers[index]

                tunnelManager.isEnabled = false
                tunnelManager.isOnDemandEnabled = false
                tunnelManager.onDemandRules = nil

                self.saveVpnManager(
                    tunnelManager,
                    operation: "stop.saveToPreferences",
                    lateCompletion: { [weak self] error in
                        DispatchQueue.main.async {
                            self?.reconcileAfterLatePreferenceWrite(
                                operation: "stop.saveToPreferences",
                                error: error
                            )
                        }
                    }
                ) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self = self, tunnelInstance == self.tunnelInstance else { return }
                        if let error {
                            self.retryStopOrReport(
                                error,
                                operation: "stop.saveToPreferences",
                                index: index,
                                reset: reset,
                                shouldRun: shouldRun,
                                managerCount: n,
                                tunnelInstance: tunnelInstance,
                                completion: completion
                            )
                            return
                        }

                        tunnelManager.connection.stopVPNTunnel()

                        // A normal stop or health retry must retain the
                        // installed profile. Removing it here makes the next
                        // connect require system authorization and, if the
                        // following save stalls, leaves the app with no tunnel
                        // configuration at all. Explicit quit/logout cleanup
                        // remains the only profile-removal path.
                        self.finishAcceptedTunnelTransition(
                            expectedStarted: false,
                            operation: "stop.health",
                            device: device,
                            index: index,
                            reset: reset,
                            shouldRun: shouldRun,
                            managerCount: n,
                            tunnelInstance: tunnelInstance,
                            completion: completion
                        )
                    }
                }
            }
        }
    }
    
    
    func stopVpnTunnelOnQuit(completion: @escaping (Error?) -> Void) {
        // remove all vpn profiles
        cancelCurrentVpnReconcile(
            error: makeVPNManagerError("VPN update cancelled while quitting", code: 13)
        )
        self.tunnelInstance += 1
        VPNManager.removeAllVpnProfiles(completion: completion)
    }

    func stopVpnTunnelOnLogout(completion: @escaping (Error?) -> Void) {
        cancelCurrentVpnReconcile(
            error: makeVPNManagerError("VPN update cancelled while logging out", code: 14)
        )
        self.tunnelInstance += 1
        VPNManager.clearTunnelLocalStateAndRemoveAllVpnProfiles(completion: completion)
    }

    private func cancelCurrentVpnReconcile(error: Error) {
        reconcileScheduled = false
        reconcileScheduleGeneration &+= 1
        reconcileInFlight = false
        activeShouldRun = nil
        pendingShouldRun = nil
        pendingForce = false
        pendingIndex = 0
        pendingReset = false
        lastAppliedShouldRun = nil
        finishVpnReconcile(error: error)
    }

    func stopVpnTunnelOnQuitAndWait() async -> Error? {
        await withCheckedContinuation { continuation in
            stopVpnTunnelOnQuit { error in
                continuation.resume(returning: error)
            }
        }
    }

    static func removeAllVpnProfiles(completion: @escaping (Error?) -> Void) {
        removeAllVpnProfilesWithIndex(index: 0, completion: completion)
    }

    static func clearTunnelLocalStateAndRemoveAllVpnProfiles(completion: @escaping (Error?) -> Void) {
        // forget the rpc transport material so the next login regenerates it
        RpcSessionStore.clear()
        sendLogoutMessageToTunnelProviders {
            removeAllVpnProfiles(completion: completion)
        }
    }

    private static func sendLogoutMessageToTunnelProviders(completion: @escaping () -> Void) {
        performVPNOperation(operation: "logout.loadAllFromPreferences") { resolve in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(managers ?? []))
                }
            }
        } completion: { (result: Result<[NETunnelProviderManager], Error>) in
            DispatchQueue.main.async {
                guard case .success(let managers) = result, !managers.isEmpty else {
                    completion()
                    return
                }

                let group = DispatchGroup()
                var sentMessage = false
                var didComplete = false

                let finish = {
                    guard !didComplete else { return }
                    didComplete = true
                    completion()
                }

                for manager in managers {
                    guard let session = manager.connection as? NETunnelProviderSession else {
                        continue
                    }

                    group.enter()
                    sentMessage = true
                    performVPNOperation(
                        operation: "logout.sendProviderMessage",
                        timeout: 2
                    ) { resolve in
                        do {
                            try session.sendProviderMessage(TunnelLogoutProviderMessage) { response in
                                resolve(.success(response))
                            }
                        } catch {
                            resolve(.failure(error))
                        }
                    } completion: { (result: Result<Data?, Error>) in
                        if case .failure(let error) = result {
                            print("[VPNManager][logout] failed to send provider logout message: \(error.localizedDescription)")
                        }
                        group.leave()
                    }
                }

                guard sentMessage else {
                    finish()
                    return
                }

                group.notify(queue: .main) {
                    finish()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    finish()
                }
            }
        }
    }

    private static func removeAllVpnProfilesWithIndex(index: Int, completion: @escaping (Error?) -> Void) {
        guard vpnProfileRemovalMayContinue(attempt: index) else {
            completion(
                makeVPNManagerError(
                    "Stopped after \(MaximumVPNProfilesToRemove) VPN profile removals without reaching an empty preference set",
                    code: 15
                )
            )
            return
        }

        performVPNOperation(operation: "removeAll.loadAllFromPreferences") { resolve in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(managers ?? []))
                }
            }
        } completion: { (result: Result<[NETunnelProviderManager], Error>) in
            DispatchQueue.main.async {
                guard case .success(let managers) = result else {
                    let error: Error
                    if case .failure(let resultError) = result {
                        error = resultError
                    } else {
                        error = makeVPNManagerError("Failed to load VPN profiles", code: 12)
                    }
                    completion(error)
                    return
                }

                guard !managers.isEmpty else {
                    completion(nil)
                    return
                }

                let tunnelManager = managers[0]
                performVPNOperation(operation: "removeAll.removeFromPreferences") { resolve in
                    tunnelManager.removeFromPreferences { error in
                        if let error {
                            resolve(.failure(error))
                        } else {
                            resolve(.success(()))
                        }
                    }
                } completion: { (removeResult: Result<Void, Error>) in
                    DispatchQueue.main.async {
                        if case .failure(let error) = removeResult {
                            completion(error)
                            return
                        }
                        VPNManager.removeAllVpnProfilesWithIndex(index: index + 1, completion: completion)
                    }
                }
            }
        }
    }
}


private class RouteLocalChangeListener: NSObject, SdkRouteLocalChangeListenerProtocol {
    
    private let c: (_ routeLocal: Bool) -> Void

    init(c: @escaping (_ routeLocal: Bool) -> Void) {
        self.c = c
    }
    
    func routeLocalChanged(_ routeLocal: Bool) {
        c(routeLocal)
    }
}

private class OfflineChangeListener: NSObject, SdkOfflineChangeListenerProtocol {
    
    private let c: (_ offline: Bool, _ vpnInterfaceWhileOffline: Bool) -> Void

    init(c: @escaping (_ offline: Bool, _ vpnInterfaceWhileOffline: Bool) -> Void) {
        self.c = c
    }
    
    func offlineChanged(_ offline: Bool, vpnInterfaceWhileOffline: Bool) {
        c(offline, vpnInterfaceWhileOffline)
    }
}

private class ConnectChangeListener: NSObject, SdkConnectChangeListenerProtocol {
    
    private let c: (_ connectEnabled: Bool) -> Void

    init(c: @escaping (_ connectEnabled: Bool) -> Void) {
        self.c = c
    }
    
    func connectChanged(_ connectEnabled: Bool) {
        c(connectEnabled)
    }
}

private class RemoteChangeListener: NSObject, SdkRemoteChangeListenerProtocol {
    
    private let c: (_ remoteConnected: Bool) -> Void

    init(c: @escaping (_ remoteConnected: Bool) -> Void) {
        self.c = c
    }
    
    func remoteChanged(_ remoteConnected: Bool) {
        c(remoteConnected)
    }
}

private class ProvideChangeListener: NSObject, SdkProvideChangeListenerProtocol {
    
    private let c: (_ provideEnabled: Bool) -> Void

    init(c: @escaping (_ provideEnabled: Bool) -> Void) {
        self.c = c
    }
    
    func provideChanged(_ provideEnabled: Bool) {
        c(provideEnabled)
    }
}

private class ProvidePausedChangeListener: NSObject, SdkProvidePausedChangeListenerProtocol {
    
    private let c: (_ providePaused: Bool) -> Void

    init(c: @escaping (_ providePaused: Bool) -> Void) {
        self.c = c
    }
    
    func providePausedChanged(_ providePaused: Bool) {
        c(providePaused)
    }
}

// RpcSession is the per-vpn-session rpc transport material: the self-signed
// client cert (pinned by the app), the server cert+key (presented by the
// extension), and the loopback host/port the extension listens on.
// The PEM values are opaque strings produced by the SDK; the app stores and
// forwards them verbatim and never manipulates the material itself.
struct RpcSession: Codable {
    let clientPem: String       // client cert + private key (app presents; stays in app)
    let clientCertPem: String   // client cert only (public; sent to the extension to pin)
    let serverPem: String       // server cert + private key (sent to the extension to present)
    let serverCertPem: String   // server cert only (public; the app pins)
    let host: String
    let port: Int

    var hostPort: String { "\(host):\(port)" }
}

// RpcSessionStore persists the last known good RpcSession in the app process so
// reconnects reuse the same material/port (avoiding an extension device
// recreation) until a connection fails.
enum RpcSessionStore {
    private static let key = "network.ur.rpcSessionLastGood"

    static func load() -> RpcSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RpcSession.self, from: data)
    }

    static func save(_ session: RpcSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
