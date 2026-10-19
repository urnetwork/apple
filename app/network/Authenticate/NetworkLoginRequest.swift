import Foundation
import URnetworkSdk

/// A displayed login flow belongs to one space/session assignment, even when
/// a replacement has the same hostname or credential bytes.
final class NetworkLoginOrigin: Sendable {
    let id = UUID()
}

/// Captured before the first producer await, then carried through registration
/// and UI delivery. Starting a pending request does not retire serving auth.
@MainActor
final class NetworkLoginRequest {
    let id = UUID()
    let origin: NetworkLoginOrigin
    let networkSpace: SdkNetworkSpace
    let api: SdkApi
    weak var manager: DeviceManager?
    var accepted = false
    var registrationStarted = false

    init(origin: NetworkLoginOrigin, networkSpace: SdkNetworkSpace, api: SdkApi, manager: DeviceManager) {
        self.origin = origin
        self.networkSpace = networkSpace
        self.api = api
        self.manager = manager
    }

    var isCurrent: Bool { manager?.isCurrentNetworkLoginRequest(self) == true }

    /// A UI/API continuation may apply effects only to its originating request.
    @discardableResult
    func publish(_ work: () -> Void) -> Bool {
        guard isCurrent else { return false }
        work()
        return true
    }
}

/// Retained by one login view hierarchy. Old views cannot mint a new request
/// after space replacement, logout, quit or an accepted explicit login.
@MainActor
final class NetworkLoginContext {
    private weak var manager: DeviceManager?
    let origin: NetworkLoginOrigin

    init(manager: DeviceManager, origin: NetworkLoginOrigin) {
        self.manager = manager
        self.origin = origin
    }

    func begin() -> NetworkLoginRequest? {
        manager?.beginNetworkLoginRequest(origin: origin)
    }
}

/// A provider callback admits its original request before queueing work. The
/// queued delivery checks the same request again; it never reads a later slot.
@MainActor
final class NetworkLoginCallback<Value> {
    let request: NetworkLoginRequest
    private var delivered = false

    init(request: NetworkLoginRequest) { self.request = request }

    @discardableResult
    func receive(
        _ value: Value,
        enqueue: (@escaping @MainActor () async -> Void) -> Void = { work in Task { await work() } },
        handle: @escaping @MainActor (Value, NetworkLoginRequest) async -> Void
    ) -> Bool {
        guard !delivered, request.isCurrent else { return false }
        delivered = true
        let request = request
        enqueue {
            guard request.isCurrent else { return }
            await handle(value, request)
        }
        return true
    }
}
