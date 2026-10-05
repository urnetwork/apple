//
//  TunnelControlSupport.swift
//  URnetworkWidgets
//
//  Starts, stops and reads the app's tunnel configuration from the widget
//  extension's process, without the SDK. This mirrors the app's own start and
//  stop paths (VPNManager.applyAutomaticRecoveryPolicy / stopVpnTunnel) so a
//  tunnel started from Control Center is one the app adopts as-is, and a
//  tunnel stopped from Control Center is left exactly as an in-app disconnect
//  leaves it.
//

import Foundation
import NetworkExtension

struct QuickConnectState: Equatable, Sendable {
    /// The app has installed its tunnel configuration on this device.
    var isConfigured: Bool
    /// The tunnel is up, or on its way up. `connecting` and `reasserting`
    /// count as on so the toggle does not snap back while the extension is
    /// still bringing the tunnel up.
    var isOn: Bool
}

enum TunnelControlSupport {

    static let providerBundleIdentifier = "network.ur.extension"

    /// How long perform() waits for the status to leave its transitional
    /// state. Well under the 30 s the system allows an intent.
    static let settleTimeout: TimeInterval = 8

    static func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        case .disconnected, .disconnecting, .invalid:
            return false
        @unknown default:
            return false
        }
    }

    static func currentState() async -> QuickConnectState {
        guard let manager = await loadManager() else {
            return QuickConnectState(isConfigured: false, isOn: false)
        }
        return QuickConnectState(isConfigured: true, isOn: isActive(manager.connection.status))
    }

    /// The app's configuration, matched by provider bundle id rather than
    /// `.first`: a device with several VPN apps installed has several.
    /// The first load in a fresh widget process can come back empty even when
    /// a configuration exists, so an empty result is retried once.
    static func loadManager() async -> NETunnelProviderManager? {
        for attempt in 0..<2 {
            let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            let ours = managers.first { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == providerBundleIdentifier
            }
            if let manager = ours ?? managers.first {
                return manager
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return nil
    }

    /// Connect or disconnect. Without an installed configuration this is an
    /// honest no-op: the control shows an "open the app" button in that case,
    /// and the app is the only process that can create the configuration.
    /// Out of balance (by a fresh App Group balance; this process cannot
    /// fetch one) a connect that would start the tunnel is refused before
    /// anything is recorded or started, and `.upgrade` tells the intent to
    /// open the app (see InsufficientBalancePolicy).
    @discardableResult
    static func setTunnel(on: Bool, source: String) async -> ConnectAttemptDecision {
        guard let manager = await loadManager() else {
            return .connect
        }

        if quickConnectDecision(
            on: on,
            tunnelActive: isActive(manager.connection.status),
            cachedBalance: WidgetSnapshotStore.loadBalance(),
            now: Date()
        ) == .upgrade {
            return .upgrade
        }

        // record first: even if the system call below fails, the app should
        // learn what the user wanted
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        TunnelIntentStore.record(
            connect: on, source: source,
            owner: configuration.flatMap(TunnelIntentOwner.fromProviderConfiguration)
        )

        do {
            if on {
                // the same automatic recovery policy the app installs before a
                // connect: enabled, reconnect on any network, survive sleep
                manager.isEnabled = true
                let connectRule = NEOnDemandRuleConnect()
                connectRule.interfaceTypeMatch = .any
                manager.onDemandRules = [connectRule]
                manager.isOnDemandEnabled = true
                if let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
                    tunnelProtocol.disconnectOnSleep = false
                    manager.protocolConfiguration = tunnelProtocol
                }
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                // names the surface, so the extension's logs say who started
                // it (TunnelIntentStore.startSource)
                try manager.connection.startVPNTunnel(
                    options: TunnelIntentStore.startOptions(source: source)
                )
            } else {
                // on-demand must be off before the stop, or the system brings
                // the tunnel straight back; disabling the configuration is
                // what the app's own stop does
                manager.isEnabled = false
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
                try await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
            }
        } catch {
            return .connect
        }

        await waitForSettledStatus(manager.connection, on: on)
        return .connect
    }

    /// The system re-reads the control's value the moment perform() returns,
    /// so wait (briefly) until the transition has actually happened. If the
    /// tunnel takes longer, the transitional state still reads correctly
    /// (connecting counts as on) and the app or the tunnel extension reloads
    /// the control once it settles.
    static func waitForSettledStatus(_ connection: NEVPNConnection, on: Bool) async {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline {
            switch connection.status {
            case .connected, .reasserting:
                if on { return }
            case .disconnected, .invalid:
                if !on { return }
            case .connecting, .disconnecting:
                break
            @unknown default:
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
