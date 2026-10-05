//
//  ReferralShareLink.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/04.
//

import SwiftUI
import URnetworkSdk

struct ReferralShareLink<Content: View>: View {
    
    // @StateObject var viewModel: ViewModel
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel

    @EnvironmentObject var deviceManager: DeviceManager
    
    let content: () -> Content
    
    init(referralLinkViewModel: ReferralLinkViewModel, content: @escaping () -> Content) {
        self.content = content
        self.referralLinkViewModel = referralLinkViewModel
    }
    
    var body: some View {
        // the code and its ur.io/c link (ReferralShare). share a generic invite
        // until the code loads (the poller keeps retrying), instead of
        // permanently disabling sharing
        let message: String = {
            if let code = referralLinkViewModel.referralCode, !code.isEmpty {
                return ReferralShare.text(code: code, networkSpace: deviceManager.networkSpace)
            }
            return String(localized: "Join me on URnetwork! Get the app and enter my referral code when you sign up.")
        }()
        ShareLink(item: message, subject: Text("URnetwork Referral Code")) {
            content()
        }
        .disabled(referralLinkViewModel.isLoading)
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

//#Preview {
//    ReferralShareLink(
//        api: SdkApi(),
//        referralLinkViewModel: ReferralLinkViewModel(api: SdkApi())
//    ) {
//        Label("Share URnetwork", systemImage: "square.and.arrow.up")
//    }
//}
