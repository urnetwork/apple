//
//  AccountActions.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/29.
//

import SwiftUI
import URnetworkSdk

/// Pro gold. Reserved for the Pro entitlement across the product — this ring, the
/// avatar ring on Android, the network-name button on ur.io. Because it is used for
/// nothing else, gold reads as "this account is Pro" rather than as decoration.
private let proGold = Color(red: 1.0, green: 0.77, blue: 0.0)
private let proGoldLight = Color(red: 1.0, green: 0.88, blue: 0.51)

struct AccountMenu: View {
    
    var isGuest: Bool
    var isPro: Bool = false
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
            .accessibilityIdentifier("acceptance.account.logout")
            
            ReferralShareLink(referralLinkViewModel: referralLinkViewModel) {
                Label("Share URnetwork", systemImage: "square.and.arrow.up")
            }
            
        } label: {
            Image("AccountMenuLabelImage")
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                /**
                 * Pro members get a glowing gold ring around their avatar.
                 *
                 * The ring is an angular gradient so the light appears to travel around
                 * it rather than sitting flat, and the glow is two stacked shadows —
                 * a tight bright one and a wide soft one — which reads as light coming
                 * off the ring rather than a drop shadow under it.
                 */
                .overlay(
                    Group {
                        if isPro {
                            Circle()
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(colors: [
                                            proGoldLight, proGold, proGoldLight, proGold, proGoldLight,
                                        ]),
                                        center: .center
                                    ),
                                    lineWidth: 2
                                )
                                .shadow(color: proGold.opacity(0.6), radius: 5)
                                .shadow(color: proGold.opacity(0.3), radius: 11)
                        }
                    }
                )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("acceptance.account.menu")
        

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
