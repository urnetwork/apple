import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// Answers the account deletion with a fixed result, as the server does.
private final class DeleteResultUrApiService: MockUrApiService {
    private let result: SdkNetworkDeleteResult

    init(result: SdkNetworkDeleteResult) {
        self.result = result
    }

    override func deleteAccount() async throws -> SdkNetworkDeleteResult {
        return result
    }
}

private func refusedResult(_ message: String) -> SdkNetworkDeleteResult {
    let error = SdkApiError()
    error.message = message
    let result = SdkNetworkDeleteResult()
    result.error = error
    return result
}

/// The server refuses an account deletion it cannot complete (a Stripe or
/// Google Play subscription it could not cancel, an App Store subscription
/// that still renews) with an error in a successful response. The account
/// still exists, so the app must not treat the deletion as done and log out.
@MainActor
struct DeleteAccountResultTests {

    @Test func aRefusedDeletionIsAFailureCarryingTheServerReason() async {
        let reason = "Could not cancel your Google Play subscription. Please try again."
        let viewModel = SettingsView.ViewModel(api: DeleteResultUrApiService(result: refusedResult(reason)))

        let result = await viewModel.deleteAccount()

        guard case .failure(let error) = result else {
            Issue.record("a refused deletion was reported as deleted, so the user is logged out of an account that still exists")
            return
        }
        guard case NetworkDeleteError.refused(let message) = error else {
            Issue.record("unexpected error \(error)")
            return
        }
        #expect(message == reason)
        // the user can try again
        #expect(viewModel.isDeletingNetwork == false)
    }

    @Test func aRefusedDeletionWithoutAReasonIsStillAFailure() async {
        let viewModel = SettingsView.ViewModel(api: DeleteResultUrApiService(result: refusedResult("")))

        let result = await viewModel.deleteAccount()

        guard case .failure = result else {
            Issue.record("a refused deletion without a message was reported as deleted")
            return
        }
    }

    @Test func aDeletionWithoutAnErrorSucceeds() async {
        let viewModel = SettingsView.ViewModel(api: DeleteResultUrApiService(result: SdkNetworkDeleteResult()))

        let result = await viewModel.deleteAccount()

        guard case .success = result else {
            Issue.record("a completed deletion was reported as failed")
            return
        }
        #expect(viewModel.isDeletingNetwork == false)
    }

    @Test func theFailureMessageShowsTheServerReasonAfterTheGenericError() {
        let generic = String(localized: "Sorry, there was an error deleting your account.")
        let reason = "Your subscription is billed through the App Store and cannot be cancelled by URnetwork."

        #expect(deleteAccountFailureMessage(NetworkDeleteError.refused(message: reason)) == "\(generic)\n\(reason)")
        #expect(deleteAccountFailureMessage(NetworkDeleteError.refused(message: "  ")) == generic)
        #expect(deleteAccountFailureMessage(NetworkDeleteError.resultInvalid) == generic)
    }
}
