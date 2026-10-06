// Fake SDK preserves already-delivered listener work across subscription close.
import Foundation

public protocol SdkConnectChangeListenerProtocol: AnyObject {
    func connectChanged(_ connectEnabled: Bool)
}

public protocol SdkSubProtocol: AnyObject {
    func close()
}

public final class FakeConnectSubscription: SdkSubProtocol {
    public private(set) var isClosed = false
    public private(set) var closeCount = 0
    private let listener: SdkConnectChangeListenerProtocol
    init(listener: SdkConnectChangeListenerProtocol) {
        self.listener = listener
    }
    public func close() {
        isClosed = true
        closeCount += 1
    }
    // Models an SDK delivery already selected before close, without claiming
    // that every SDK delivers callbacks after close.
    public func deliverCaptured(_ connectEnabled: Bool) {
        listener.connectChanged(connectEnabled)
    }
}

public final class SdkDeviceRemote: NSObject {
    public var connectEnabled: Bool
    public private(set) var subscriptions: [FakeConnectSubscription] = []
    public init(connectEnabled: Bool) {
        self.connectEnabled = connectEnabled
    }
    public func add(_ listener: SdkConnectChangeListenerProtocol) -> SdkSubProtocol {
        let subscription = FakeConnectSubscription(listener: listener)
        subscriptions.append(subscription)
        return subscription
    }
    public func getConnectEnabled() -> Bool {
        connectEnabled
    }
    public func emit(_ connectEnabled: Bool) {
        self.connectEnabled = connectEnabled
        for subscription in subscriptions where !subscription.isClosed {
            subscription.deliverCaptured(connectEnabled)
        }
    }
}
