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
         * Referral code entry. Instant accounts can be referred too -- the
         * server links the referral on any create path. Mirrors the referral
         * cluster in CreateNetworkViewModel.
         */
        @Published var isPresentedAddBonusSheet: Bool = false

        @Published var bonusReferralCode: String = "" {
            didSet {
                if bonusReferralCode != oldValue {
                    isValidReferralCode = false
                    referralValidationComplete = false
                    referralCodeInputSupportingText = ""
                }
            }
        }

        @Published private(set) var isValidReferralCode: Bool = false
        @Published private(set) var isCappedReferralCode: Bool = false
        @Published private(set) var isValidatingReferralCode: Bool = false
        @Published private(set) var referralValidationComplete: Bool = false
        @Published private(set) var referralCodeInputSupportingText: LocalizedStringKey = ""

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

        private func buildReferralInputSupportingText() {
            if !referralValidationComplete {
                referralCodeInputSupportingText = ""
            } else if isCappedReferralCode {
                referralCodeInputSupportingText = "This code has been used up"
            } else if !isValidReferralCode {
                referralCodeInputSupportingText = "This code is not valid"
            } else {
                referralCodeInputSupportingText = ""
            }
        }

        func validateReferralCode() async -> Result<SdkValidateReferralCodeResult, Error> {

            if isValidatingReferralCode {
                return .failure(NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "validation already in progress"]))
            }

            isValidatingReferralCode = true
            referralValidationComplete = false

            defer {
                isValidatingReferralCode = false
                referralValidationComplete = true
                buildReferralInputSupportingText()
            }

            do {
                let result = try await urApiService.validateReferralCode(bonusReferralCode)
                isValidReferralCode = result.isValid
                isCappedReferralCode = result.isCapped
                return .success(result)
            } catch {
                isValidReferralCode = false
                return .failure(error)
            }

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
                let referralCode = (isValidReferralCode && !isCappedReferralCode)
                    ? bonusReferralCode
                    : nil
                let result = try await urApiService.createInstantAccount(referralCode: referralCode)
                return result
            } catch {
                errorMessage = "There was an error creating your account. Please try again."
                return nil
            }

        }

    }

}
