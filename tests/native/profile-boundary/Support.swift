// App services are substituted at their existing type boundaries; the gateway,
// controller, planner and configuration compile unchanged from production.
import Combine
import Foundation
import URnetworkSdk

enum AppStartupMode: CaseIterable {
    case production, hardwareNoVPN, rejectedHardwareTestRequest
    var allowsVPNProfileSystemAccess: Bool { self == .production }
}

enum HardwareNoVPNLaunchContract {
    // A synthetic policy input, not a new production mode override. Real
    // launch mode is immutable; changing this forces callback boundary checks.
    static var current: AppStartupMode = .production
}

enum TunnelIntentStore {
    static let sourceApp = "fixture-app"
    static func startOptions(source: String) -> [String: NSObject] {
        ["fixture-source": source as NSString]
    }
}

enum TunnelProviderIdentity {
    static let splitTunnelBundleIdentifier = "com.example.fixture.splittunnel"
}

final class SystemExtensionActivator: ObservableObject {
    static var activations = 0
    @Published var state: SystemExtensionActivationState = .activated(willCompleteAfterReboot: false)
    init(extensionBundleIdentifier: String) {}
    func activateIfNeeded() {
        Self.activations += 1
        state = .activated(willCompleteAfterReboot: false)
    }
    func openSystemSettings() {}
}

final class DeviceManager: ObservableObject {
    @Published var device: SdkDeviceRemote?
    @Published var parsedJwt: String? = "fixture-account"
    init(device: SdkDeviceRemote? = nil) { self.device = device }
}

final class BlockActionsStore: ObservableObject {
    @Published var authoritativeExcludedApps: [String]?
    init(apps: [String]? = nil) { authoritativeExcludedApps = apps }
}

enum Checks {
    static var failures = 0
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() {
            failures += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }
    static func finish(_ name: String) {
        guard failures == 0 else { exit(1) }
        print("\(name): \(count) semantic checks passed")
    }
}
