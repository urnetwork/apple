// Synthetic framework boundary. No Apple profile service is imported or used.
import Foundation

public enum ProfileCalls {
    public static var events: [String] = []
    public static var startOptions: [[String: NSObject]?] = []
    public static var tunnelManagers: [NETunnelProviderManager] = []
    public static var transparentManagers: [NETransparentProxyManager] = []
    public static var holdSave = false
    public static var saveEntered: (() -> Void)?
    public static var pendingSave: ((Error?) -> Void)?
    public static var operationError: Error?

    public static func reset() {
        events = []
        startOptions = []
        tunnelManagers = []
        transparentManagers = []
        holdSave = false
        saveEntered = nil
        pendingSave = nil
        operationError = nil
    }
}

public enum NEVPNStatus {
    case invalid, disconnected, connecting, connected, reasserting, disconnecting
}

open class NEVPNConnection {
    public var status: NEVPNStatus = .disconnected
    public init() {}
    open func startVPNTunnel() throws {
        try startVPNTunnel(options: nil)
    }
    open func startVPNTunnel(options: [String: NSObject]?) throws {
        ProfileCalls.events.append("start")
        ProfileCalls.startOptions.append(options)
        if let error = ProfileCalls.operationError { throw error }
    }
    open func stopVPNTunnel() {
        ProfileCalls.events.append("stop")
    }
}

open class NETunnelProviderSession: NEVPNConnection {
    public func sendProviderMessage(_ data: Data, responseHandler: ((Data?) -> Void)?) throws {
        ProfileCalls.events.append("message")
        if let error = ProfileCalls.operationError { throw error }
        responseHandler?(nil)
    }
}

open class NEVPNProtocol {
    public var serverAddress: String?
    public init() {}
}

public class NETunnelProviderProtocol: NEVPNProtocol {
    public var providerBundleIdentifier: String?
    public var providerConfiguration: [String: Any]?
}

// Transparent and packet managers are siblings in the native SDK, not
// subclasses of one another. Preserve that relationship in the fake.
open class NEVPNManager {
    public var connection = NEVPNConnection()
    public var protocolConfiguration: NEVPNProtocol?
    public var localizedDescription: String?
    public var isEnabled = false
    public init() {
        ProfileCalls.events.append("make:\(String(describing: type(of: self)))")
    }
    open func saveToPreferences(completionHandler: @escaping (Error?) -> Void) {
        ProfileCalls.events.append("save")
        if ProfileCalls.holdSave {
            precondition(ProfileCalls.pendingSave == nil)
            ProfileCalls.pendingSave = completionHandler
        } else {
            completionHandler(ProfileCalls.operationError)
        }
        ProfileCalls.saveEntered?()
    }
    open func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) {
        ProfileCalls.events.append("reload")
        completionHandler(ProfileCalls.operationError)
    }
    open func removeFromPreferences(completionHandler: @escaping (Error?) -> Void) {
        ProfileCalls.events.append("remove")
        completionHandler(ProfileCalls.operationError)
    }
}

public class NETunnelProviderManager: NEVPNManager {
    public static func loadAllFromPreferences(
        completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void
    ) {
        ProfileCalls.events.append("load-tunnels")
        completionHandler(ProfileCalls.tunnelManagers, ProfileCalls.operationError)
    }
    public static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        ProfileCalls.events.append("load-tunnels-async")
        if let error = ProfileCalls.operationError { throw error }
        return ProfileCalls.tunnelManagers
    }
}

public class NETransparentProxyManager: NEVPNManager {
    public static func loadAllFromPreferences(
        completionHandler: @escaping ([NETransparentProxyManager]?, Error?) -> Void
    ) {
        ProfileCalls.events.append("load-transparent")
        completionHandler(ProfileCalls.transparentManagers, ProfileCalls.operationError)
    }
}

public extension Notification.Name {
    static let NEVPNStatusDidChange = Notification.Name("fixture.profile-status")
}
