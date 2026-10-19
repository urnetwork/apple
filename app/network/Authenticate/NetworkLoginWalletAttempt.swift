import Foundation

/// Each sign handoff carries a fresh callback path. Both wallets append their
/// result query to redirect_link, so a rejection identifies the same attempt as
/// a signature. Credential acceptance additionally verifies the signed message.
@MainActor
final class NetworkLoginWalletAttempt {
    let id = UUID().uuidString
    let request: NetworkLoginRequest
    let message: String
    private var completed = false

    init(request: NetworkLoginRequest, message: String) {
        self.request = request
        self.message = message
    }

    static func redirectLink(_ base: String, attemptId: String?) -> String {
        guard let attemptId else { return base }
        return base + "/login/" + attemptId
    }

    func owns(_ url: URL) -> Bool {
        guard !completed, request.isCurrent, url.scheme == "urnetwork",
              ["phantom-sign-message", "solflare-sign-message"].contains(url.host ?? "") else { return false }
        return url.path == "/login/" + id
    }

    @discardableResult
    func fail(_ url: URL, publish: () -> Void) -> Bool {
        guard owns(url) else { return false }
        completed = true
        publish()
        return true
    }

    @discardableResult
    func receive(
        _ url: URL, signature: String, publicKey: String,
        enqueue: (@escaping @MainActor () async -> Void) -> Void = { work in Task { await work() } },
        handle: @escaping @MainActor (String, String, String, NetworkLoginRequest) async -> Void
    ) -> Bool {
        guard owns(url), NetworkLoginWalletProof.matches(message: message, signature: signature, publicKey: publicKey) else { return false }
        completed = true
        return NetworkLoginCallback(request: request).receive((message, signature, publicKey), enqueue: enqueue) { value, request in
            await handle(value.0, value.1, value.2, request)
        }
    }
}
