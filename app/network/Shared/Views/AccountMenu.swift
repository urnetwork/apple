//
//  AccountActions.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/29.
//

import SwiftUI
import URnetworkSdk

struct AccountMenu: View {
    
    var isGuest: Bool
    var logout: () -> Void
    var networkName: String?
    @Binding var isPresentedCreateAccount: Bool
    
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    var body: some View {
    
        Menu {
            
            Button(action: {}) {
                HStack {
                    Text(networkName ?? "Guest")
                    Spacer()
                    Image("ur.symbols.tab.account")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
            }
            
            
            if isGuest {
                Button(action: {
                    isPresentedCreateAccount = true
                }) {
                    Label("Create account", systemImage: "person.crop.circle.badge.plus")
                }
            }
            
            Button(action: {
                logout()
            }) {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            
            ReferralShareLink(referralLinkViewModel: referralLinkViewModel) {
                Label("Share URnetwork", systemImage: "square.and.arrow.up")
            }
            
        } label: {
            Image("AccountMenuLabelImage")
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        }
        .menuStyle(.borderlessButton)
        

    }
}

//#Preview {
//    AccountMenu(
//        isGuest: false,
//        logout: {},
//        isPresentedCreateAccount: .constant(false),
//        referralLinkViewModel: ReferralLinkViewModel(api: SdkApi())
//    )
//}
