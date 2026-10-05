//
//  ReferralsViewModel.swift
//  URnetwork
//
//  The referral network this network signed up with (the code it entered),
//  for the Referrals section. The network's own code, count and terms come
//  from the shared ReferralLinkViewModel, which polls them app-wide.
//

import Foundation
import SwiftUI
import URnetworkSdk

/// What the referral network card offers.
enum ReferralNetworkAction: Equatable {
    /// no referral network: the primary "Add referral code" action
    case addCode
    /// the network this one signed up with, and Update
    case update(networkName: String)

    /// The action for the network this one signed up with: Add referral code
    /// when there is none.
    static func of(networkName: String?) -> ReferralNetworkAction {
        guard let networkName, !networkName.isEmpty else {
            return .addCode
        }
        return .update(networkName: networkName)
    }
}

extension ReferralsView {

    @MainActor
    class ViewModel: ObservableObject {

        let api: UrApiServiceProtocol

        @Published private(set) var referralNetwork: SdkReferralNetwork? = nil
        @Published private(set) var isLoading: Bool = false
        @Published var presentUpdateReferralNetworkSheet: Bool = false

        init(api: UrApiServiceProtocol) {
            self.api = api
        }

        func fetchReferralNetwork() async {
            if isLoading {
                return
            }
            isLoading = true
            defer { isLoading = false }

            do {
                let result = try await api.getReferralNetwork()

                if let error = result.error {
                    print("[ReferralsView] fetch referral network error: \(error.message)")
                    self.referralNetwork = nil
                    return
                }

                self.referralNetwork = result.network
            } catch {
                print("[ReferralsView] error fetching referral network: \(error)")
            }
        }
    }
}
