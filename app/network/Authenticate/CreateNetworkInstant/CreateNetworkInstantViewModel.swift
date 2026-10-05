//
//  CreateNetworkInstantViewModel.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

extension CreateNetworkInstantView {

    @MainActor
    class ViewModel: ObservableObject {

        private let urApiService: UrApiServiceProtocol

        /// The sign-up form's "Periodic product updates" switch, on by default.
        @Published var productUpdates: Bool = true

        @Published var termsAgreed: Bool = false {
            didSet {
                errorMessage = nil
                validateForm()
            }
        }

        @Published private(set) var isCreatingAccount: Bool = false

        @Published private(set) var formIsValid: Bool = false

        @Published private(set) var errorMessage: String?

        /**
         * The optional referral code, always visible above Create Account.
         * Instant accounts can be referred too -- the server links the
         * referral on any create path.
         */
        let referralEntry: ReferralCodeEntry

        let domain = "CreateNetworkInstantViewModel"

        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
            self.referralEntry = ReferralCodeEntry(validate: { code in
                try await urApiService.validateReferralCode(code)
            })
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
                let result = try await urApiService.createInstantAccount(
                    referralCode: referralEntry.createCode,
                    productUpdatesOptOut: !productUpdates
                )
                return result
            } catch {
                errorMessage = "There was an error creating your account. Please try again."
                return nil
            }

        }

    }

}
