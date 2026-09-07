import Foundation
import URnetworkExtensionSdk

enum TunnelDeviceKeySaveOutcome: Equatable {
    case saved
    case skipped
    case failed
}

// Both initial persistence and provider-key callbacks use the actual device's
// checked writer. Native admission rejects already-retired callbacks; the SDK
// owns final auth/store admission if retirement races this earlier observation.
// No native lock spans SDK I/O, and Apple never persists provider-secret lists.
final class TunnelDeviceKeyPersistence: NSObject, SdkProvideSecretKeysListenerProtocol {
    private let device: SdkDeviceLocal
    private let isCurrent: () -> Bool
    private let reportFailure: () -> Void

    init(device: SdkDeviceLocal, isCurrent: @escaping () -> Bool, reportFailure: @escaping () -> Void) {
        self.device = device
        self.isCurrent = isCurrent
        self.reportFailure = reportFailure
    }

    @discardableResult
    func save() -> TunnelDeviceKeySaveOutcome {
        guard !device.getDone(), isCurrent() else { return .skipped }
        do {
            try device.saveKeyMaterial()
            return .saved
        } catch {
            // Errors cannot cross this callback as paths, credentials or keys.
            // Keep the existing report-only policy: no retry, reset or fallback.
            reportFailure()
            return .failed
        }
    }

    func provideSecretKeysChanged(_ ignored: SdkProvideSecretKeyList?) {
        // Consume the actual device level, not the delayed callback payload.
        save()
    }
}
