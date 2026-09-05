// SPDX-License-Identifier: MPL-2.0

import Foundation
import NetworkExtension

struct VPNProfileSystemAccessError: LocalizedError {
    var errorDescription: String? {
        "VPN profile system access is disabled for this process"
    }
}

/// The only source-level gateway to NetworkExtension profile persistence and
/// tunnel start/stop APIs. The hardware lane preserves ordinary DeviceManager
/// startup while omitting VPNManager construction, and this lower boundary
/// independently refuses every system profile operation if a future caller
/// reaches it by mistake.
enum VPNProfileSystem {
    static func accessAllowed(mode: AppStartupMode) -> Bool {
        mode.allowsVPNProfileSystemAccess
    }

    @discardableResult
    static func performIfAllowed(
        mode: AppStartupMode,
        operation: () -> Void
    ) -> Bool {
        guard accessAllowed(mode: mode) else {
            return false
        }
        operation()
        return true
    }

    static func loadAllFromPreferences(
        completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void
    ) {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            completionHandler(nil, VPNProfileSystemAccessError())
            return
        }
        NETunnelProviderManager.loadAllFromPreferences(
            completionHandler: completionHandler
        )
    }

    static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            throw VPNProfileSystemAccessError()
        }
        return try await NETunnelProviderManager.loadAllFromPreferences()
    }

    static func makeManager() throws -> NETunnelProviderManager {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            throw VPNProfileSystemAccessError()
        }
        return NETunnelProviderManager()
    }

    static func saveToPreferences(
        _ manager: NETunnelProviderManager,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            completionHandler(VPNProfileSystemAccessError())
            return
        }
        manager.saveToPreferences(completionHandler: completionHandler)
    }

    static func loadFromPreferences(
        _ manager: NETunnelProviderManager,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            completionHandler(VPNProfileSystemAccessError())
            return
        }
        manager.loadFromPreferences(completionHandler: completionHandler)
    }

    static func removeFromPreferences(
        _ manager: NETunnelProviderManager,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            completionHandler(VPNProfileSystemAccessError())
            return
        }
        manager.removeFromPreferences(completionHandler: completionHandler)
    }

    static func startVPNTunnel(_ manager: NETunnelProviderManager) throws {
        guard accessAllowed(mode: HardwareNoVPNLaunchContract.current) else {
            throw VPNProfileSystemAccessError()
        }
        try manager.connection.startVPNTunnel()
    }

    @discardableResult
    static func stopVPNTunnel(_ manager: NETunnelProviderManager) -> Bool {
        performIfAllowed(mode: HardwareNoVPNLaunchContract.current) {
            manager.connection.stopVPNTunnel()
        }
    }
}
