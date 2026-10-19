import AuthenticationServices
import SwiftUI

struct NetworkLoginAppleButton: View {
    let begin: () -> NetworkLoginRequest?
    let complete: @MainActor (Result<ASAuthorization, Error>, NetworkLoginRequest) async -> Void
    @State private var attemptId = UUID()

    var body: some View {
        NetworkLoginAppleAttemptButton(begin: begin, complete: complete, finished: { attemptId = UUID() })
            .id(attemptId)
    }
}

private struct NetworkLoginAppleAttemptButton: View {
    let begin: () -> NetworkLoginRequest?
    let complete: @MainActor (Result<ASAuthorization, Error>, NetworkLoginRequest) async -> Void
    let finished: () -> Void
    @StateObject private var attempt = NetworkLoginAppleAttempt()

    var body: some View {
        // Capture this invocation's object in both native closures. Replacing
        // the view for a retry leaves any old native closure with the old object.
        let attempt = attempt
        SignInWithAppleButton(.signIn) { request in
            attempt.begin(request, request: begin)
        } onCompletion: { result in
            if attempt.complete(result, handle: complete) { finished() }
        }
    }
}
