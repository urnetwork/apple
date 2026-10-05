//
//  ProvidePowerStore.swift
//  URnetwork
//
//  What providing does on battery, the user's choice (P077), and the power
//  state the provider card reads to say why providing is paused. The packet
//  tunnel extension makes the pause decision itself (ProvidePausePolicy); the
//  app hands it the mode as a provider message when the choice changes, when
//  a tunnel connects, and when the app comes to the foreground.
//

import Foundation
import NetworkExtension
import SwiftUI

@MainActor
class ProvidePowerStore: ObservableObject {

    @Published var mode: ProvidePowerMode = ProvidePowerModeStore.load() {
        didSet {
            guard mode != oldValue else {
                return
            }
            ProvidePowerModeStore.save(mode)
            sendModeToTunnel()
        }
    }

    /// Low Power Mode and external power, as this device reports them; the
    /// extension reads the same system state.
    @Published private(set) var power = ProvidePowerState(
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
        charging: nil
    )

    private let chargingMonitor = ProvideChargingMonitor()
    private var powerStateObserver: NSObjectProtocol?
    private var tunnelStatusObserver: NSObjectProtocol?

    init() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePower()
            }
        }
        // a tunnel that starts gets the mode at once: it may have started
        // with the last mode it was sent, or none. The saved mode is the
        // current one
        tunnelStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard let session = notification.object as? NETunnelProviderSession,
                  session.status == .connected else {
                return
            }
            Self.send(ProvidePowerModeStore.load(), to: session)
        }
        chargingMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.updatePower()
            }
        }
    }

    deinit {
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        if let tunnelStatusObserver {
            NotificationCenter.default.removeObserver(tunnelStatusObserver)
        }
        chargingMonitor.stop()
    }

    /// The battery's reason to pause providing, which the provider card says
    /// when the device reports providing paused.
    var powerPauseReason: ProvidePauseReason? {
        ProvidePausePolicy.powerPauseReason(power: power, mode: mode)
    }

    /// The app came to the foreground: re-read the power state, and hand the
    /// mode to a tunnel that started while the app was closed.
    func applicationDidBecomeActive() {
        updatePower()
        sendModeToTunnel()
    }

    private func updatePower() {
        let power = ProvidePowerState(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            charging: chargingMonitor.charging
        )
        if power != self.power {
            self.power = power
        }
    }

    /// Best effort: a tunnel that is not running gets the mode when it
    /// connects.
    private func sendModeToTunnel() {
        let mode = self.mode
        VPNProfileSystem.loadAllFromPreferences { managers, _ in
            for manager in managers ?? [] {
                guard let session = manager.connection as? NETunnelProviderSession else {
                    continue
                }
                switch session.status {
                case .connected, .connecting, .reasserting:
                    Self.send(mode, to: session)
                default:
                    break
                }
            }
        }
    }

    private nonisolated static func send(_ mode: ProvidePowerMode, to session: NETunnelProviderSession) {
        do {
            try session.sendProviderMessage(ProvidePowerModeMessage.encode(mode)) { _ in }
        } catch {
            print("[ProvidePowerStore]send provide power mode failed: \(error)")
        }
    }
}

extension ProvidePowerMode {

    /// What the "When on battery" picker shows.
    var label: LocalizedStringResource {
        switch self {
        case .always:
            return "Keep providing"
        case .pauseInLowPower:
            return "Pause in Low Power Mode"
        case .chargingOnly:
            return "Pause until charging"
        }
    }
}
