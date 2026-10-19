import Foundation

/// Only for request/response callbacks that resume a continuation once. SDK
/// listeners keep SdkCallback's repeat-delivery semantics.
class OneShotSdkCallback<ResultType, ProtocolType>: SdkCallback<ResultType, ProtocolType> where ProtocolType: AnyObject {
    private let deliveryLock = NSLock()
    private var delivered = false

    override func handleResult(_ result: ResultType?, err: Error?) {
        deliveryLock.lock()
        guard !delivered else { deliveryLock.unlock(); return }
        delivered = true
        deliveryLock.unlock()
        super.handleResult(result, err: err)
    }
}
