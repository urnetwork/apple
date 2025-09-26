//
//  ParticipateRefer.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI

struct ParticipateReferView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let close: () -> Void
    
    var body: some View {
        
        ScrollView {
         
            VStack(alignment: .leading) {
                
                Text("Refer friends")
                    .font(themeManager.currentTheme.titleFont)
                
                Spacer().frame(height: 32)
  
                // todo - cap referrals + referral bar
                
//                VStack {
//                 
//                    // todo - refer bar
//                    
//                    Text("This bar in the app  also shows you how many referrals you have given.")
//                    
//                    Text("You have 5 referrals, and each referral gives you and the person you refer 30GiB data per month, for life.")
//                    
//                }
                
                Text("Step 2")
                    .font(themeManager.currentTheme.titleCondensedFont)
                
                VStack(alignment: .leading) {
                    
                    Text("Refer some people and watch your free data go up.")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    
                    Spacer().frame(height: 4)
                    
                    // move this to the refer bar when it's added
                    Text("You have 5 referrals, and each referral gives you and the person you refer 30GiB data per month, for life.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    
                    Spacer().frame(height: 16)
                    
                    UrButton(text: "Refer a friend", action: {})
                    
                    Spacer().frame(height: 16)
                    
                    Divider()
                    
                    Spacer().frame(height: 16)
                    
                    UrButton(text: "Get connected", action: {
                        close()
        //                dismiss()
                    })
                    
                }
                .padding()
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(16)
                
//                Spacer().frame(height: 32)
//                
//                UrButton(text: "Get connected", action: {
//                    close()
//    //                dismiss()
//                })
                
                Spacer()
                
            }
            .padding()
                        
        }
    }
}

#Preview {
    ParticipateReferView(
        close: {}
    )
}
