//
//  UpdateReferralNetworkSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 6/12/25.
//

import Foundation
import URnetworkSdk
import SwiftUICore

extension UpdateReferralNetworkSheet {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        @Published var referralCode: String = ""
        
        @Published var codeInputSupportingText: LocalizedStringKey = ""
        
        @Published var isUpdatingReferralNetwork: Bool = false
        
        @Published var unlinkAlertVisible: Bool = false
        
        @Published var isUnlinkingReferralNetwork: Bool = false
        
        var api: SdkApi
        
        init(api: SdkApi) {
            self.api = api
        }
        
        /**
         * Update referral network with referral code
         */
        func updateReferralNetwork() async -> Result<Void, Error> {
            
            if (isUpdatingReferralNetwork) {
                return .failure(UpdateReferralNetworkError.inProgress)
            }
            
            isUpdatingReferralNetwork = true
            self.codeInputSupportingText = ""

            do {

                let result: SdkSetNetworkReferralResult = try await withCheckedThrowingContinuation { [weak self] continuation in

                    guard let self = self else { return }

                    let callback = UpdateReferralNetworkCallback { result, err in

                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }

                        guard let result = result else {
                            continuation.resume(throwing: NSError(domain: "UpdateReferralNetworkViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkSetNetworkReferralResult result is nil"]))
                            return
                        }

                        continuation.resume(returning: result)
                    }
                    
                    let args = SdkSetNetworkReferralArgs()
                    args.referralCode = self.referralCode

                    api.setNetworkReferral(args, callback: callback)

                }
                
                if result.error != nil {
                    self.codeInputSupportingText = "Invalid referral code. Please try again."
                    print("fetch referral network result.error: \(String(describing: result.error?.message))")
                    return .failure(UpdateReferralNetworkError.unknown)
                }

                isUpdatingReferralNetwork = false
                
                return .success(())
                

            } catch(let error) {
                print("Error updating referral network: \(error)")
                self.codeInputSupportingText = "Something went wrong. Please try again later."
                isUpdatingReferralNetwork = false
                return .failure(UpdateReferralNetworkError.unknown)
            }
            
        }
        
        /**
         * Unlink the referral network
         */
        func unlinkReferralNetwork() async -> Result<Void, Error> {
            
            if (isUnlinkingReferralNetwork) {
                return .failure(UpdateReferralNetworkError.inProgress)
            }
            
            isUnlinkingReferralNetwork = true
            self.codeInputSupportingText = ""

            do {

                let _: SdkUnlinkReferralNetworkResult = try await withCheckedThrowingContinuation { [weak self] continuation in

                    guard let self = self else { return }

                    let callback = UnlinkReferralNetworkCallback { result, err in

                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }

                        guard let result = result else {
                            continuation.resume(throwing: NSError(domain: "UpdateReferralNetworkViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkUnlinkReferralNetworkResult result is nil"]))
                            return
                        }

                        continuation.resume(returning: result)
                    }
                    
                    api.unlinkReferralNetwork(callback)

                }

                isUnlinkingReferralNetwork = false
                
                return .success(())
                

            } catch(let error) {
                print("Error updating referral network: \(error)")
                isUnlinkingReferralNetwork = false
                return .failure(UpdateReferralNetworkError.unknown)
            }
            
        }
        
    }
    
    private class UpdateReferralNetworkCallback: SdkCallback<SdkSetNetworkReferralResult, SdkSetNetworkReferralCallbackProtocol>, SdkSetNetworkReferralCallbackProtocol {
        func result(_ result: SdkSetNetworkReferralResult?, err: Error?) {
            handleResult(result, err: err)
        }
    }
    
    private class UnlinkReferralNetworkCallback: SdkCallback<SdkUnlinkReferralNetworkResult, SdkUnlinkReferralNetworkCallbackProtocol>, SdkUnlinkReferralNetworkCallbackProtocol {
        func result(_ result: SdkUnlinkReferralNetworkResult?, err: Error?) {
            handleResult(result, err: err)
        }
    }
    
    enum UpdateReferralNetworkError: Error {
        case inProgress
        case resultInvalid
        case unknown
    }
    
}
