import AuthenticationServices
import Foundation
import Combine

/// One native authorization invocation. A callback retained by an older
/// SignInWithAppleButton always reaches this object, including errors without
/// an echoed state; it cannot consume the next button's request.
@MainActor
final class NetworkLoginAppleAttempt: ObservableObject {
    private var started = false
    private var callback: NetworkLoginCallback<Result<ASAuthorization, Error>>?

    func begin(_ authorization: ASAuthorizationAppleIDRequest, request: () -> NetworkLoginRequest?) {
        guard !started else { return }
        started = true
        guard let request = request() else { return }
        callback = NetworkLoginCallback(request: request)
        authorization.state = request.id.uuidString
        authorization.requestedScopes = [.email]
    }

    @discardableResult
    func complete(
        _ result: Result<ASAuthorization, Error>,
        enqueue: (@escaping @MainActor () async -> Void) -> Void = { work in Task { await work() } },
        handle: @escaping @MainActor (Result<ASAuthorization, Error>, NetworkLoginRequest) async -> Void
    ) -> Bool {
        guard let callback else { return false }
        if case .success(let authorization) = result {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == callback.request.id.uuidString else { return false }
        }
        self.callback = nil
        callback.receive(result, enqueue: enqueue, handle: handle)
        return true
    }
}
