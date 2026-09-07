import Foundation
import URnetworkExtensionSdk

// Shared by the provider's admitted recovery and the native SDK control. Only
// a genuinely missing consumer forces reconstruction; equal healthy choices
// retain the SDK's idempotent setter and save-before-live admission.
func applyTunnelRecoveryDestination(_ device: SdkDeviceLocal, location: SdkConnectLocation?) throws {
    if location != nil && device.getConnectLocation() != nil && !device.getConnectEnabled() {
        try device.reconnectChecked(location)
    } else {
        try device.setConnectLocationChecked(location)
    }
}

// The actual DeviceLocal callback advertises successful durable publication,
// not the API's earlier token observation. SDK getters are outside native
// locks. A retired device or an obsolete callback cannot wake a new owner.
final class TunnelDeviceAuthSettlementObserver: NSObject, SdkJwtRefreshListenerProtocol {
    private let device: SdkDeviceLocal
    private let isCurrent: () -> Bool
    private let settled: () -> Void
    private let accepted: (String) -> Void

    init(
        device: SdkDeviceLocal, isCurrent: @escaping () -> Bool,
        settled: @escaping () -> Void, accepted: @escaping (String) -> Void = { _ in }
    ) {
        self.device = device
        self.isCurrent = isCurrent
        self.settled = settled
        self.accepted = accepted
    }

    func jwtRefreshed(_ jwt: String?) {
        guard isCurrent(), !device.getDone(), let jwt, !jwt.isEmpty,
              device.getClientJwt() == jwt else { return }
        // Failure of the independent shared-Keychain mirror cannot consume
        // the device's successful publication event.
        settled()
        accepted(jwt)
    }
}
