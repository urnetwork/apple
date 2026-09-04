//
//  ReferralsSheet.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The Account section's Referrals screen, presented as a sheet from places
 * outside the Account tab (the connect drawer's referral row). There is one
 * referrals design: this wraps ReferralsView unchanged and only adds the
 * sheet chrome and the points store the Account tab would otherwise own.
 */
struct ReferralsSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    @StateObject private var accountPointsStore: AccountPointsStore

    let api: UrApiServiceProtocol
    let dismiss: () -> Void

    init(
        api: UrApiServiceProtocol,
        sdkApi: SdkApi?,
        referralLinkViewModel: ReferralLinkViewModel,
        dismiss: @escaping () -> Void
    ) {
        self.api = api
        self.referralLinkViewModel = referralLinkViewModel
        self.dismiss = dismiss
        _accountPointsStore = StateObject(wrappedValue: AccountPointsStore(api: sdkApi))
    }

    var body: some View {
        NavigationStack {
            ReferralsView(
                api: api,
                referralLinkViewModel: referralLinkViewModel,
                accountPointsStore: accountPointsStore
            )
            .navigationTitle("Refer and earn")
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
