// Directly exercises every real gateway operation against the counting module.
import Foundation
import NetworkExtension

@main struct GatewayBoundary {
    static func expectAccessError(_ operation: () throws -> Void, _ name: String) {
        do {
            try operation()
            Checks.expect(false, "\(name) did not throw")
        } catch {
            Checks.expect(error is VPNProfileSystemAccessError, "\(name) returned another error")
        }
    }

    static func main() async {
        let tunnel = NETunnelProviderManager()
        let proxy = NETransparentProxyManager()
        for mode in [AppStartupMode.hardwareNoVPN, .rejectedHardwareTestRequest] {
            HardwareNoVPNLaunchContract.current = mode
            ProfileCalls.reset()
            var completions = 0
            VPNProfileSystem.loadAllFromPreferences { managers, error in
                completions += 1
                Checks.expect(managers == nil && error is VPNProfileSystemAccessError, "denied packet load result")
            }
            VPNProfileSystem.loadAllTransparentProxyManagers { managers, error in
                completions += 1
                Checks.expect(managers == nil && error is VPNProfileSystemAccessError, "denied transparent load result")
            }
            for manager in [tunnel as NEVPNManager, proxy as NEVPNManager] {
                let completion: (Error?) -> Void = { error in
                    completions += 1
                    Checks.expect(error is VPNProfileSystemAccessError, "denied mutation result")
                }
                VPNProfileSystem.saveToPreferences(manager, completionHandler: completion)
                VPNProfileSystem.loadFromPreferences(manager, completionHandler: completion)
                VPNProfileSystem.removeFromPreferences(manager, completionHandler: completion)
                Checks.expect(!VPNProfileSystem.stopVPNTunnel(manager), "denied stop returned true")
            }
            expectAccessError({ _ = try VPNProfileSystem.makeManager() }, "packet construction")
            expectAccessError({ _ = try VPNProfileSystem.makeTransparentProxyManager() }, "transparent construction")
            expectAccessError({ try VPNProfileSystem.startVPNTunnel(tunnel) }, "packet start")
            expectAccessError({ try VPNProfileSystem.startTransparentProxy(proxy) }, "transparent start")
            do {
                _ = try await VPNProfileSystem.loadAllFromPreferences()
                Checks.expect(false, "denied async load did not throw")
            } catch {
                Checks.expect(error is VPNProfileSystemAccessError, "denied async load result")
            }
            Checks.expect(completions == 8, "denied callback was missing or repeated: \(completions)")
            Checks.expect(ProfileCalls.events.isEmpty, "denied framework effects: \(ProfileCalls.events)")
        }

        HardwareNoVPNLaunchContract.current = .production
        ProfileCalls.reset()
        ProfileCalls.tunnelManagers = [tunnel]
        ProfileCalls.transparentManagers = [proxy]
        var completions = 0
        VPNProfileSystem.loadAllFromPreferences { managers, error in
            completions += 1
            Checks.expect(managers?.count == 1 && managers?.first === tunnel && error == nil, "packet load identity")
        }
        VPNProfileSystem.loadAllTransparentProxyManagers { managers, error in
            completions += 1
            Checks.expect(managers?.count == 1 && managers?.first === proxy && error == nil, "transparent load identity")
        }
        do {
            let managers = try await VPNProfileSystem.loadAllFromPreferences()
            Checks.expect(managers.count == 1 && managers.first === tunnel, "async packet load identity")
            _ = try VPNProfileSystem.makeManager()
            _ = try VPNProfileSystem.makeTransparentProxyManager()
            for manager in [tunnel as NEVPNManager, proxy as NEVPNManager] {
                let completion: (Error?) -> Void = { error in
                    completions += 1
                    Checks.expect(error == nil, "production mutation added an error")
                }
                VPNProfileSystem.saveToPreferences(manager, completionHandler: completion)
                VPNProfileSystem.loadFromPreferences(manager, completionHandler: completion)
                VPNProfileSystem.removeFromPreferences(manager, completionHandler: completion)
                Checks.expect(VPNProfileSystem.stopVPNTunnel(manager), "production stop returned false")
            }
            try VPNProfileSystem.startVPNTunnel(tunnel)
            try VPNProfileSystem.startTransparentProxy(proxy)
        } catch {
            Checks.expect(false, "production gateway threw: \(error)")
        }
        Checks.expect(completions == 8, "production callback was missing or repeated")
        Checks.expect(ProfileCalls.events == [
            "load-tunnels", "load-transparent", "load-tunnels-async",
            "make:NETunnelProviderManager", "make:NETransparentProxyManager",
            "save", "reload", "remove", "stop", "save", "reload", "remove", "stop", "start", "start",
        ], "production forwarding sequence: \(ProfileCalls.events)")
        Checks.expect(ProfileCalls.startOptions.count == 2, "start option count")
        if ProfileCalls.startOptions.count == 2 {
            Checks.expect(ProfileCalls.startOptions[0] == TunnelIntentStore.startOptions(source: TunnelIntentStore.sourceApp),
                          "packet start source changed")
            Checks.expect(ProfileCalls.startOptions[1] == nil, "transparent start options changed")
        }

        // The gateway must forward framework failures verbatim, once.
        ProfileCalls.reset()
        let frameworkError = NSError(domain: "com.example.profile-fixture", code: 7)
        ProfileCalls.operationError = frameworkError
        completions = 0
        VPNProfileSystem.loadAllTransparentProxyManagers { _, error in
            completions += 1
            Checks.expect((error as NSError?) === frameworkError, "load error identity")
        }
        for operation in [VPNProfileSystem.saveToPreferences, VPNProfileSystem.loadFromPreferences, VPNProfileSystem.removeFromPreferences] {
            operation(proxy) { error in
                completions += 1
                Checks.expect((error as NSError?) === frameworkError, "mutation error identity")
            }
        }
        do {
            try VPNProfileSystem.startTransparentProxy(proxy)
            Checks.expect(false, "transparent start discarded framework error")
        } catch {
            Checks.expect((error as NSError) === frameworkError, "start error identity")
        }
        Checks.expect(completions == 4, "framework error completion count")
        Checks.expect(ProfileCalls.events == ["load-transparent", "save", "reload", "remove", "start"],
                      "framework failure forwarding sequence")
        Checks.finish("gateway profile boundary")
    }
}
