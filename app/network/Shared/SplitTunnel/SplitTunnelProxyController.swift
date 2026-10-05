//
//  SplitTunnelProxyController.swift
//  URnetwork
//
//  macOS only: keeps the split tunnel system extension and its transparent
//  proxy configuration in step with the excluded apps and the user's connect
//  intent. Three inputs feed it -- the excluded apps BlockActionsStore can
//  vouch for, the device's connect intent, the activation state of the
//  extension -- and one loop acts on them: SplitTunnelProxyPlan names the
//  next step, this performs it against SystemExtensions and
//  NETransparentProxyManager, observes, and asks again.
//
//  The extension is activated (OSSystemExtensionRequest) the first time an
//  app is excluded and at every launch after that, which is also how an
//  updated app replaces the installed copy; the user approves it once in
//  System Settings. Saving the configuration the first time asks the user
//  to allow URnetwork's proxy configuration. The proxy runs while the user
//  wants the VPN connected, is stopped otherwise and when the app quits, and
//  the configuration is removed once no app is excluded and at logout.
//
//  All state changes on the main queue; framework callbacks hop onto it.
//

#if os(macOS)

import AppKit
import Combine
import Foundation
import NetworkExtension
import URnetworkSdk

private class SplitTunnelConnectListener: NSObject, SdkConnectChangeListenerProtocol {
    private let callback: (Bool) -> Void
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }
    func connectChanged(_ connectEnabled: Bool) {
        callback(connectEnabled)
    }
}

final class SplitTunnelProxyController: ObservableObject {

    /// The extension is built on the macOS 15 flow API.
    static var isSupported: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    /// The configuration's name in System Settings (a product name, not
    /// translated), and the extension's CFBundleDisplayName.
    static let configurationName = "URnetwork Split Tunnel"

    /// A step that does not converge (a store that keeps disagreeing with
    /// what was saved) ends the pass instead of looping.
    private static let maximumStepsPerPass = 8

    @Published private(set) var status: SplitTunnelProxyStatus = .off

    private let activator = SystemExtensionActivator(
        extensionBundleIdentifier: TunnelProviderIdentity.splitTunnelBundleIdentifier
    )
    private var inputs = SplitTunnelProxyInputs(
        wantedApps: nil,
        connectEnabled: false,
        extensionState: .idle,
        observed: nil
    )
    private var manager: NETransparentProxyManager?
    /// The last step failed. Cleared by a change the user makes (the list,
    /// the extension, Retry) and not by connect, so a declined permission
    /// prompt is not asked again on every connect.
    private var failed = false
    private var reconciling = false
    private var reconcileAgain = false
    private var isSetUp = false

    private var cancellables = Set<AnyCancellable>()
    private var connectSub: SdkSubProtocol?
    private var connectionObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    deinit {
        connectSub?.close()
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// Once, from the app's root view (the stores are main actor objects).
    @MainActor
    func setup(deviceManager: DeviceManager, blockActionsStore: BlockActionsStore) {
        guard !isSetUp,
              Self.isSupported,
              VPNProfileSystem.accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            return
        }
        isSetUp = true

        activator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.setExtensionState(state)
            }
            .store(in: &cancellables)
        deviceManager.$device
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                self?.setDevice(device)
            }
            .store(in: &cancellables)
        // logout: the next account's rules are its own
        deviceManager.$parsedJwt
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loggedIn in
                if !loggedIn {
                    self?.setWantedApps([])
                }
            }
            .store(in: &cancellables)
        blockActionsStore.$authoritativeExcludedApps
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] excludedApps in
                self?.setWantedApps(excludedApps)
            }
            .store(in: &cancellables)
        observeTermination()
        reconcile()
    }

    /// The tunnel stops with the app (VPNManager.stopVpnTunnelOnQuit), and so
    /// does the proxy.
    private func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.manager?.connection.stopVPNTunnel()
        }
    }

    /// After a failure the Apps section offers: load the configuration again
    /// (a failed load left nothing to go by), activate again, save again.
    func retry() {
        failed = false
        inputs.observed = nil
        switch inputs.extensionState {
        case .failed, .notInApplications:
            activator.activateIfNeeded()
        default:
            break
        }
        reconcile()
    }

    func openSystemSettings() {
        activator.openSystemSettings()
    }

    // MARK: inputs

    private func setWantedApps(_ excludedApps: [String]) {
        guard inputs.wantedApps != excludedApps else {
            return
        }
        inputs.wantedApps = excludedApps
        failed = false
        reconcile()
    }

    private func setExtensionState(_ state: SystemExtensionActivationState) {
        guard inputs.extensionState != state else {
            return
        }
        inputs.extensionState = state
        failed = false
        reconcile()
    }

    private func setConnectEnabled(_ connectEnabled: Bool) {
        guard inputs.connectEnabled != connectEnabled else {
            return
        }
        inputs.connectEnabled = connectEnabled
        reconcile()
    }

    private func setDevice(_ device: SdkDeviceRemote?) {
        connectSub?.close()
        connectSub = nil
        guard let device else {
            setConnectEnabled(false)
            return
        }
        connectSub = device.add(SplitTunnelConnectListener { [weak self] connectEnabled in
            DispatchQueue.main.async {
                self?.setConnectEnabled(connectEnabled)
            }
        })
        setConnectEnabled(device.getConnectEnabled())
    }

    // MARK: the loop

    private func reconcile() {
        guard !reconciling else {
            reconcileAgain = true
            return
        }
        reconciling = true
        runNextStep(remaining: Self.maximumStepsPerPass)
    }

    private func finishPass() {
        let status = SplitTunnelProxyPlan.status(inputs, failed: failed)
        if self.status != status {
            self.status = status
        }
        reconciling = false
        if reconcileAgain {
            reconcileAgain = false
            reconcile()
        }
    }

    private func runNextStep(remaining: Int) {
        let next: (Bool) -> Void = { [weak self] succeeded in
            guard let self else {
                return
            }
            if !succeeded {
                self.failed = true
                self.finishPass()
            } else if remaining <= 1 {
                self.finishPass()
            } else {
                self.runNextStep(remaining: remaining - 1)
            }
        }
        switch SplitTunnelProxyPlan.nextStep(inputs) {
        case .none:
            finishPass()
        case .load:
            load(completion: next)
        case .activateExtension:
            if !failed {
                activator.activateIfNeeded()
            }
            // the activation result re-runs the plan
            finishPass()
        case .save(let configuration):
            if failed {
                finishPass()
            } else {
                save(configuration, completion: next)
            }
        case .remove:
            remove(completion: next)
        case .start:
            start()
            // the status notification re-runs the plan
            finishPass()
        case .stop:
            manager?.connection.stopVPNTunnel()
            finishPass()
        }
    }

    // MARK: steps

    private func load(completion: @escaping (Bool) -> Void) {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let error {
                    print("[SplitTunnelProxyController]load failed: \(error.localizedDescription)")
                    self.setManager(nil)
                    completion(false)
                    return
                }
                self.setManager((managers ?? []).first { Self.isSplitTunnel($0) })
                completion(true)
            }
        }
    }

    private func save(_ configuration: SplitTunnelProxyConfiguration, completion: @escaping (Bool) -> Void) {
        let manager = self.manager ?? NETransparentProxyManager()
        let tunnelProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = TunnelProviderIdentity.splitTunnelBundleIdentifier
        // required, and shown in System Settings; the proxy has no server
        tunnelProtocol.serverAddress = "URnetwork"
        tunnelProtocol.providerConfiguration = configuration.providerConfiguration
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = Self.configurationName
        manager.isEnabled = true
        let wasRunning = inputs.observed?.isRunning ?? false

        manager.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let error {
                    // includes the user declining the permission prompt
                    print("[SplitTunnelProxyController]save failed: \(error.localizedDescription)")
                    completion(false)
                    return
                }
                // a saved configuration is loaded again before it can start
                manager.loadFromPreferences { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else {
                            return
                        }
                        if let error {
                            print("[SplitTunnelProxyController]reload failed: \(error.localizedDescription)")
                            completion(false)
                            return
                        }
                        self.setManager(manager)
                        if wasRunning {
                            self.handOver(configuration)
                        }
                        completion(true)
                    }
                }
            }
        }
    }

    /// The running proxy takes the new list without a restart. If it cannot
    /// be told, it is stopped, and the plan starts it again on the saved list.
    private func handOver(_ configuration: SplitTunnelProxyConfiguration) {
        guard let manager else {
            return
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            manager.connection.stopVPNTunnel()
            return
        }
        do {
            try session.sendProviderMessage(configuration.messageData) { _ in }
        } catch {
            print("[SplitTunnelProxyController]hand over failed: \(error.localizedDescription)")
            manager.connection.stopVPNTunnel()
        }
    }

    private func remove(completion: @escaping (Bool) -> Void) {
        guard let manager else {
            setManager(nil)
            completion(true)
            return
        }
        manager.removeFromPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let error {
                    print("[SplitTunnelProxyController]remove failed: \(error.localizedDescription)")
                    completion(false)
                    return
                }
                self.setManager(nil)
                completion(true)
            }
        }
    }

    private func start() {
        guard let manager else {
            return
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            print("[SplitTunnelProxyController]start failed: \(error.localizedDescription)")
            failed = true
        }
    }

    // MARK: observation

    private func setManager(_ manager: NETransparentProxyManager?) {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
            self.connectionObserver = nil
        }
        self.manager = manager
        inputs.observed = Self.observe(manager)
        guard let manager else {
            return
        }
        connectionObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.manager === manager else {
                return
            }
            self.inputs.observed = Self.observe(manager)
            self.reconcile()
        }
    }

    private static func isSplitTunnel(_ manager: NETransparentProxyManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == TunnelProviderIdentity.splitTunnelBundleIdentifier
    }

    private static func observe(_ manager: NETransparentProxyManager?) -> SplitTunnelProxyObserved {
        guard let manager else {
            return .absent
        }
        let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol
        let isRunning: Bool
        switch manager.connection.status {
        case .connecting, .connected, .reasserting:
            isRunning = true
        case .invalid, .disconnected, .disconnecting:
            isRunning = false
        @unknown default:
            isRunning = false
        }
        return SplitTunnelProxyObserved(
            configuration: SplitTunnelProxyConfiguration(providerConfiguration: tunnelProtocol?.providerConfiguration),
            isInstalled: true,
            isEnabled: manager.isEnabled,
            isRunning: isRunning
        )
    }
}

#endif
