// Fake preferences and tunnel operations; this module never links NetworkExtension.
import Foundation

public enum NEVPNStatus {
    case invalid, disconnected, connecting, connected, reasserting, disconnecting
}

public extension Notification.Name {
    static let NEVPNStatusDidChange = Notification.Name("example.test.status.changed")
}

public class NEVPNProtocol: NSObject {}

public final class NETunnelProviderProtocol: NEVPNProtocol {
    public var providerBundleIdentifier: String?
    public var serverAddress: String?
    public var providerConfiguration: [String: Any]?
}

public class NEVPNConnection: NSObject {
    public var status: NEVPNStatus = .disconnected
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public func startVPNTunnel() throws {
        try startVPNTunnel(options: nil)
    }
    public func startVPNTunnel(options: [String: NSObject]?) throws {
        startCount += 1
        status = .connected
    }
    public func stopVPNTunnel() {
        stopCount += 1
        status = .disconnected
    }
}

public final class NETunnelProviderSession: NEVPNConnection {
    public private(set) var messageCount = 0
    public func sendProviderMessage(_ message: Data, responseHandler: ((Data?) -> Void)?) throws {
        messageCount += 1
        responseHandler?(nil)
    }
}

public class NEVPNManager: NSObject {
    public var protocolConfiguration: NEVPNProtocol?
    public var localizedDescription: String?
    public var isEnabled = false
    public let connection = NETunnelProviderSession()
    public private(set) var saveCount = 0
    public private(set) var reloadCount = 0
    public private(set) var removeCount = 0
    public func saveToPreferences(completionHandler: @escaping (Error?) -> Void) {
        saveCount += 1
        completionHandler(nil)
    }
    public func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) {
        reloadCount += 1
        completionHandler(nil)
    }
    public func removeFromPreferences(completionHandler: @escaping (Error?) -> Void) {
        removeCount += 1
        completionHandler(nil)
    }
}

// Mirror the native SDK's sibling relationship under NEVPNManager.
public final class NETransparentProxyManager: NEVPNManager {
    public static var loadCount = 0
    public static func loadAllFromPreferences(completionHandler: @escaping ([NETransparentProxyManager]?, Error?) -> Void) {
        loadCount += 1
        completionHandler([], nil)
    }
}

public final class NETunnelProviderManager: NEVPNManager {
    public static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
        completionHandler([], nil)
    }
    public static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        []
    }
}
