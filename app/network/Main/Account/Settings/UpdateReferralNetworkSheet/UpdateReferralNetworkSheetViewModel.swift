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
        
        var api: UrApiServiceProtocol
        
        init(api: UrApiServiceProtocol) {
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

                let result = try await api.setNetworkReferral(self.referralCode)
                
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
                
                let _ = try await api.unlinkReferralNetwork()

                isUnlinkingReferralNetwork = false
                
                return .success(())
                

            } catch(let error) {
                print("Error updating referral network: \(error)")
                isUnlinkingReferralNetwork = false
                return .failure(UpdateReferralNetworkError.unknown)
            }
            
        }
        
    }
    
}
