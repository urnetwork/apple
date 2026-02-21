//
//  GuestModeSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/10.
//

import SwiftUI

struct GuestModeSheet: View {
    
    @Binding var termsAgreed: Bool
    let isCreatingGuestNetwork: Bool
    let onCreateGuestNetwork: () -> Void
    
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack {
            
            HStack {
             
                Text("Try guest mode")
                    .font(themeManager.currentTheme.secondaryTitleFont)
                
                Spacer()
                
            }
            
            Spacer().frame(height: 24)
            
            UrSwitchToggle(isOn: $termsAgreed) {
                Text("I agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
            
            Spacer().frame(height: 24)
            
            UrButton(
                text: "Enter URnetwork",
                action: {
                    onCreateGuestNetwork()
                },
                enabled: termsAgreed && !isCreatingGuestNetwork
            )
            
        }
        .padding()
    }
}

#Preview {
    GuestModeSheet(
        termsAgreed: .constant(false),
        isCreatingGuestNetwork: false,
        onCreateGuestNetwork: {}
    )
}
