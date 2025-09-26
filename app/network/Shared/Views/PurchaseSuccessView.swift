//
//  PurchaseSuccessView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/26/25.
//

import SwiftUI

struct PurchaseSuccessView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var dismiss: () -> Void
    
    var body: some View {
        ZStack {
            Image("UpgradeSuccessBackground")
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                // .edgesIgnoringSafeArea(.all)
            
            VStack {
                         
                Spacer()
                
                VStack {
                    
                    HStack {
                        Image("ur.symbols.globe")
                        
                        Spacer()
                    }
                    
                    Spacer().frame(height: 12)
                    
                    HStack {
                        Text("You're premium.")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            .font(themeManager.currentTheme.titleCondensedFont)
                        Spacer()
                    }
                    
                    Spacer().frame(height: 8)
                    
                    HStack {
                        Text("Thanks for building the new internet with us")
                            .font(themeManager.currentTheme.titleFont)
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                        
                        Spacer()
                    }
                    
                    Spacer().frame(height: 64)
                    
                    UrButton(
                        text: "Close",
                        action: {
                            dismiss()
                        },
                        style: .outlinePrimary
                    )
                    
            
                }
                .padding(24)
                .background(.urLightYellow)
                .cornerRadius(12)
                .padding()
                .frame(maxWidth: .infinity)
                
            }
            .frame(maxWidth: .infinity)
            
        }
    }
    
}

#Preview {
    PurchaseSuccessView(
        dismiss: {}
    )
}
