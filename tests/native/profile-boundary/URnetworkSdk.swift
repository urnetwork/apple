// Only the listener surface used by the real split-tunnel controller.
import Foundation

public protocol SdkConnectChangeListenerProtocol: AnyObject {
    func connectChanged(_ connectEnabled: Bool)
}

public protocol SdkSubProtocol {
    func close()
}

public final class SdkDeviceRemote {
    public var connectEnabled: Bool
    public var listener: SdkConnectChangeListenerProtocol?
    public init(connectEnabled: Bool = false) {
        self.connectEnabled = connectEnabled
    }
    public func getConnectEnabled() -> Bool { connectEnabled }
    public func add(_ listener: SdkConnectChangeListenerProtocol) -> SdkSubProtocol {
        self.listener = listener
        return Subscription()
    }
    private final class Subscription: SdkSubProtocol {
        func close() {}
    }
}
