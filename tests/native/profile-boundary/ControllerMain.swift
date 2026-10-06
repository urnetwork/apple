// Runs the real controller with fake framework effects. Barriers are callback
// entry/completion and published state, never timing or queue polling.
import AppKit
import Combine
import Foundation
import NetworkExtension
import URnetworkSdk

@main struct ControllerBoundary {
    @MainActor static func main() async {
        for mode in [AppStartupMode.hardwareNoVPN, .rejectedHardwareTestRequest] {
            ProfileCalls.reset()
            HardwareNoVPNLaunchContract.current = mode
            let controller = SplitTunnelProxyController()
            let device = DeviceManager(device: SdkDeviceRemote(connectEnabled: true))
            let rules = BlockActionsStore(apps: ["com.example.excluded"])
            controller.setup(deviceManager: device, blockActionsStore: rules)
            controller.retry()
            // Load is invoked synchronously before retry returns. The callback
            // may publish asynchronously, but cannot hide a framework call.
            Checks.expect(ProfileCalls.events.isEmpty,
                          "\(mode) controller reached framework: \(ProfileCalls.events)")
            Checks.expect(SystemExtensionActivator.activations == 0,
                          "denied setup activated an extension")
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        ProfileCalls.reset()
        HardwareNoVPNLaunchContract.current = .production
        let controller = SplitTunnelProxyController()
        let device = DeviceManager(device: SdkDeviceRemote(connectEnabled: true))
        let rules = BlockActionsStore(apps: ["com.example.excluded"])
        ProfileCalls.holdSave = true
        await withCheckedContinuation { continuation in
            ProfileCalls.saveEntered = { continuation.resume() }
            controller.setup(deviceManager: device, blockActionsStore: rules)
        }
        Checks.expect(ProfileCalls.events == ["load-transparent", "make:NETransparentProxyManager", "save"],
                      "production setup did not reach exactly one held save: \(ProfileCalls.events)")
        let releaseSave = ProfileCalls.pendingSave!
        ProfileCalls.pendingSave = nil
        ProfileCalls.saveEntered = nil
        HardwareNoVPNLaunchContract.current = .hardwareNoVPN
        ProfileCalls.events = []
        var statusSubscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            statusSubscription = controller.$status.dropFirst().first().sink { _ in
                continuation.resume()
            }
            releaseSave(nil)
        }
        Checks.expect(ProfileCalls.events.isEmpty,
                      "save completion bypassed policy for followup: \(ProfileCalls.events)")
        Checks.expect(controller.status == .failed, "denied reload did not fail the controller pass")
        withExtendedLifetime(statusSubscription) {}
        // A held completion crosses the boundary deterministically. This is
        // fault injection; real launch policy does not change during a pass.
        Checks.finish("controller profile boundary")
    }
}
