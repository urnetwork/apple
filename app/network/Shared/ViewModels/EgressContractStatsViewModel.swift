import Foundation
import Combine
import URnetworkSdk

/// Owns the egress-stat subscription for the lifetime of the connect view.
@MainActor
final class EgressContractStatsViewModel: ObservableObject {
    @Published private(set) var latestContractStats: SdkContractStats?
    private var subscription: (any SdkSubProtocol)?

    init(device: SdkDeviceRemote?) {
        subscription = device?.addEgressContractStatsChangeListener(
            EgressContractStatsListener { [weak self] stats in
                // SDK callbacks may arrive on an RPC worker.
                DispatchQueue.main.async { [weak self] in
                    self?.latestContractStats = stats
                }
            }
        )
    }

    deinit {
        subscription?.close()
    }
}

private final class EgressContractStatsListener: NSObject, SdkContractStatsChangeListenerProtocol {
    private let callback: (SdkContractStats?) -> Void

    init(_ callback: @escaping (SdkContractStats?) -> Void) {
        self.callback = callback
    }

    func contractStatsChanged(_ stats: SdkContractStats?) {
        callback(stats)
    }
}
