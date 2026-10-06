// Only external app collaborators are faked; controller and planner are real.
import Foundation
import Combine
import URnetworkSdk

final class SystemExtensionActivator: ObservableObject {
    @Published var state: SystemExtensionActivationState = .idle
    init(extensionBundleIdentifier: String) {}
    func activateIfNeeded() {
        fatalError("unexpected activation in a ready-controller test")
    }
    func openSystemSettings() {
        fatalError("settings must not be opened by the test")
    }
}

enum TunnelProviderIdentity {
    static let splitTunnelBundleIdentifier = "example.synthetic.split-tunnel"
}

enum AppStartupMode {
    case production
    var allowsVPNProfileSystemAccess: Bool { true }
}

enum HardwareNoVPNLaunchContract {
    static let current: AppStartupMode = .production
}

enum TunnelIntentStore {
    static let sourceApp = "example.synthetic.app"
    static func startOptions(source: String) -> [String: NSObject] {
        ["example.synthetic.source": source as NSString]
    }
}

final class DeviceManager: ObservableObject {
    @Published var device: SdkDeviceRemote?
    @Published var parsedJwt: String?
}

final class BlockActionsStore: ObservableObject {
    @Published var authoritativeExcludedApps: [String]?
}
