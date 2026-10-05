//
//  CreateNetworkViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import Foundation
import URnetworkSdk
import SwiftUI

private class NetworkCheckCallback: SdkCallback<SdkNetworkCheckResult, SdkNetworkCheckCallbackProtocol>, SdkNetworkCheckCallbackProtocol {
    func result(_ result: SdkNetworkCheckResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum AuthType {
    case password
    case apple
    case google
    case solana
}

/// The message shown when creating the network fails: the server's reason
/// when it refused the create with one, otherwise the generic error. A taken
/// name submitted while the availability check was failing is caught here.
func createNetworkFailureMessage(_ error: Error) -> String {
    if case NetworkCreateError.refused(let message) = error {
        let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty {
            return reason
        }
    }
    return "There was an error creating your network. Please try again."
}

extension CreateNetworkView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private let urApiService: UrApiServiceProtocol
        private var networkNameValidationVc: SdkNetworkNameValidationViewController?
        private var networkNameCheck: NetworkNameCheck?
        static let networkNameTooShort: LocalizedStringKey = "Network names must be 6 characters or more"
        static let networkNameUnavailable: LocalizedStringKey = "This network name is already taken"
        static let networkNameCheckFailed: LocalizedStringKey = "Couldn't check availability. You can still continue."
        static let networkNameAvailable: LocalizedStringKey = "Nice! This network name is available"
        private static let minPasswordLength = 12
        private let domain = "CreateNetworkView.ViewModel"
        
        private var authType: AuthType
        
        // `checkNetworkName` and `schedule` replace the online check and the
        // main queue timers in tests
        init(
            api: SdkApi,
            urApiService: UrApiServiceProtocol,
            authType: AuthType,
            checkNetworkName: NetworkNameCheck.Check? = nil,
            schedule: @escaping NetworkNameCheck.Schedule = ViewModel.scheduleOnMain
        ) {
            self.urApiService = urApiService
            self.authType = authType
            
            let check: NetworkNameCheck.Check
            if let checkNetworkName {
                check = checkNetworkName
            } else {
                let networkNameValidationVc = SdkNetworkNameValidationViewController(api)
                self.networkNameValidationVc = networkNameValidationVc
                check = { networkName, onResult in
                    ViewModel.checkOnline(networkNameValidationVc, networkName: networkName, onResult: onResult)
                }
            }
            
            networkNameCheck = NetworkNameCheck(
                check: check,
                schedule: schedule,
                onStateChange: { [weak self] state in
                    self?.applyNetworkNameCheck(state)
                }
            )
            
            setNetworkNameSupportingText(ViewModel.networkNameTooShort)
        }
        
        /// Runs `action` on the main queue after `delay`; the returned
        /// function cancels it.
        nonisolated static func scheduleOnMain(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return { workItem.cancel() }
        }
        
        /// One online availability check. An error or a missing result answers
        /// nil, which the name check treats as failed, not as a taken name.
        nonisolated private static func checkOnline(
            _ networkNameValidationVc: SdkNetworkNameValidationViewController?,
            networkName: String,
            onResult: @escaping (Bool?) -> Void
        ) {
            guard let networkNameValidationVc else {
                onResult(nil)
                return
            }
            let callback = NetworkCheckCallback { result, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("error checking network name: \(error.localizedDescription)")
                        onResult(nil)
                        return
                    }
                    onResult(result?.available)
                }
            }
            networkNameValidationVc.networkCheck(networkName, callback: callback)
        }
        
        @Published var networkName: String = "" {
            didSet {
                if oldValue != networkName {
                    createNetworkErrorMessage = nil
                    checkNetworkName()
                }
            }
        }
        
        @Published private(set) var networkNameValidationState: ValidationState = .notChecked
        
        @Published private(set) var networkNameCheckState: NetworkNameCheckState = .empty
        
        @Published private(set) var referralCodeInputSupportingText: LocalizedStringKey = ""
        
        @Published var password: String = "" {
            didSet {
                createNetworkErrorMessage = nil
                validateForm()
            }
        }
        
        @Published private(set) var formIsValid: Bool = false
        
        @Published private(set) var networkNameSupportingText: LocalizedStringKey = ""
        
        /// The sign-up form's "Periodic product updates" switch, on by default.
        @Published var productUpdates: Bool = true

        @Published var termsAgreed: Bool = false {
            didSet {
                createNetworkErrorMessage = nil
                validateForm()
            }
        }
        
        @Published private(set) var isCreatingNetwork: Bool = false
        
        @Published private(set) var createNetworkErrorMessage: String?
        
        func setCreateNetworkErrorMessage(_ message: String?) {
            createNetworkErrorMessage = message
        }
        
        @Published var isPresentedAddBonusSheet: Bool = false
        
        @Published private(set) var isValidReferralCode: Bool = false
        
        @Published private(set) var isCappedReferralCode: Bool = false
        
        @Published var bonusReferralCode: String = "" {
            didSet {
                self.isValidReferralCode = false
                self.referralValidationFailed = false
                self.buildReferralInputSupportingText()
            }
        }

        @Published private(set) var isValidatingReferralCode: Bool = false
        @Published private(set) var referralValidationComplete: Bool = false
        // the check itself failed (no network, a rate limit, a server error):
        // not the same as the server answering that the code is invalid
        @Published private(set) var referralValidationFailed: Bool = false
        
        private func setNetworkNameSupportingText(_ text: LocalizedStringKey) {
            networkNameSupportingText = text
        }
        
        private func buildReferralInputSupportingText() {
            
            var msg: LocalizedStringKey = ""
            
            if !self.isValidatingReferralCode && !self.bonusReferralCode.isEmpty && self.referralValidationComplete {

                if self.referralValidationFailed {
                    msg = LocalizedStringKey("Something went wrong. Please try again later.")
                } else if (self.isCappedReferralCode) {
                    msg = LocalizedStringKey("This code has been used up")
                } else if (!self.isValidReferralCode) {
                    msg = LocalizedStringKey("This code is not valid")
                }

            }
            
            
            self.referralCodeInputSupportingText = msg
        }
        
        private func validateForm() {
            // todo - need to update validation to handle jwtAuth too (no password)
            // a failed availability check allows create: the server checks the name again
            formIsValid = networkNameCheckState.allowsCreate &&
                            (
                                // if auth type is password, check password length
                                (authType == .password && password.count >= ViewModel.minPasswordLength)
                                // otherwise, no need to check password length
                                || (authType == .apple || authType == .google || authType == .solana)
                            ) &&
                            termsAgreed
        }
        
        func validateReferralCode() async -> Result<SdkValidateReferralCodeResult, Error> {
            
            if isValidatingReferralCode {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "already validating"]))
            }
            
            isValidatingReferralCode = true
            referralValidationComplete = false
            
            do {
                
                let result = try await urApiService.validateReferralCode(bonusReferralCode)
                    
                self.isValidReferralCode = result.isValid
                self.isCappedReferralCode = result.isCapped
                self.referralValidationFailed = false
                self.isValidatingReferralCode = false
                self.referralValidationComplete = true

                self.buildReferralInputSupportingText()

                return .success(result)

            } catch(let error) {

                self.isValidatingReferralCode = false
                self.isValidReferralCode = false
                self.referralValidationFailed = true
                self.referralValidationComplete = true
                
                self.buildReferralInputSupportingText()
                
                return .failure(error)
                
            }
            
        }
        
        // debounced, retried and timed out by NetworkNameCheck
        private func checkNetworkName() {
            networkNameCheck?.validate(networkName)
        }
        
        private func applyNetworkNameCheck(_ state: NetworkNameCheckState) {
            networkNameCheckState = state
            
            switch state {
            case .empty, .tooShort:
                setNetworkNameSupportingText(ViewModel.networkNameTooShort)
                networkNameValidationState = .notChecked
            case .checking:
                networkNameValidationState = .validating
            case .available:
                setNetworkNameSupportingText(ViewModel.networkNameAvailable)
                networkNameValidationState = .valid
            case .unavailable:
                setNetworkNameSupportingText(ViewModel.networkNameUnavailable)
                networkNameValidationState = .invalid
            case .failed:
                // not a verdict on the name, so not styled as an error
                setNetworkNameSupportingText(ViewModel.networkNameCheckFailed)
                networkNameValidationState = .notChecked
            }
            
            validateForm()
        }
        
        func createNetwork(
            userAuth: String?,
            authJwt: String?,
            authType: String?,
            walletAuth: SdkWalletAuthArgs?
        ) async -> LoginNetworkResult {
            
            if !formIsValid {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Create network form is invalid"]))
            }
            
            if isCreatingNetwork {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Network creation already in progress"]))
            }
            
            self.createNetworkErrorMessage = nil
            self.isCreatingNetwork = true
            
            do {
                
                let args = SdkNetworkCreateArgs()
                args.userName = ""
                args.networkName = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
                args.terms = termsAgreed
                // the sign-up form's "Periodic product updates" switch; off = opted out
                args.productUpdatesOptOut = !productUpdates
                args.verifyOtpNumeric = true


                if let userAuth = userAuth {
                    args.userAuth = userAuth
                    args.password = password
                }

                if let authJwt, let authType {
                    args.authJwt = authJwt
                    args.authJwtType = authType
                }

                if let walletAuth {
                    args.walletAuth = walletAuth
                }

                if self.isValidReferralCode && !self.isCappedReferralCode {
                    args.referralCode = self.bonusReferralCode
                }
                
                let result = try await urApiService.createNetwork(args)
                self.isCreatingNetwork = false
                return result

            } catch {
                self.isCreatingNetwork = false
                
                return .failure(error)
            }
            
        }
        
    }
    
}
