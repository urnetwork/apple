//
//  CreateNetworkInstantViewModel.swift
//  URnetwork
//

import Foundation
import URnetworkSdk

extension CreateNetworkInstantView {

    @MainActor
    class ViewModel: ObservableObject {

        private let urApiService: UrApiServiceProtocol

        @Published var termsAgreed: Bool = false {
            didSet {
                errorMessage = nil
                validateForm()
            }
        }

        @Published private(set) var isCreatingAccount: Bool = false

        @Published private(set) var formIsValid: Bool = false

        @Published private(set) var errorMessage: String?

        let domain = "CreateNetworkInstantViewModel"

        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }

        func setErrorMessage(_ message: String?) {
            errorMessage = message
        }

        private func validateForm() {
            formIsValid = termsAgreed && !isCreatingAccount
        }

        func createInstantAccount() async -> (jwt: String, seedphrase: String)? {

            if isCreatingAccount {
                return nil
            }

            guard termsAgreed else {
                errorMessage = "You must agree to the Terms and Privacy Policy"
                return nil
            }

            isCreatingAccount = true
            errorMessage = nil

            defer {
                isCreatingAccount = false
            }

            do {
                let result = try await urApiService.createInstantAccount()
                return result
            } catch {
                errorMessage = "There was an error creating your account. Please try again."
                return nil
            }

        }

    }

}
