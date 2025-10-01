//
//  ParticipateRefer.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI

struct ParticipateReferView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    
    let close: () -> Void
    let totalReferrals: Int
    let referralCode: String
    
    var body: some View {
        
        ScrollView {
         
            VStack(alignment: .leading) {
                
                Text("Step 2")
                    .font(themeManager.currentTheme.titleFont)
                
//                Spacer().frame(height: 32)
  
                // todo - cap referrals + referral bar
                
                VStack(alignment: .leading) {
                    
                    HStack {
                     
                        Text("Refer friends")
                            .font(themeManager.currentTheme.toolbarTitleFont)
                        
                        Spacer()
                        
                        Text("\(totalReferrals)/5")
                            .font(themeManager.currentTheme.toolbarTitleFont)
                        
                    }
                 
                    Spacer().frame(height: 8)
                    
                    ReferBar(referralCount: totalReferrals)
                    
                    Spacer().frame(height: 8)
                    
//                    Text("This bar in the app  also shows you how many referrals you have given.")
//                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 4)
                    
//                    Text("You have 5 referrals, and each referral gives you and the person you refer 30GiB data per month, for life.")
//                        .font(themeManager.currentTheme.bodyFont)
                    
                    
                    Text("You get +30GiB / month")
                        .font(themeManager.currentTheme.bodyFont)
                    Text("Your friend gets +30GiB / month")
                        .font(themeManager.currentTheme.bodyFont)
                    Text("For life!")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 16)
                    
                    Divider()
                    
                    Spacer().frame(height: 16)
                    
                    Text("Refer some people and watch your free data go up.")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    
                    Spacer().frame(height: 16)
                    
                    UrLabel(text: "Bonus referral code")
                    
                    Button(action: {
                        
                        copyToPasteboard(referralCode)
                        
                        // snackbar not showing above fullScreenCover
                        snackbarManager.showSnackbar(message: "Bonus referral code copied to clipboard")
                            
                    }) {
                        HStack {
                            Text(referralCode)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Image(systemName: "document.on.document")
                        }
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        Rectangle()
                            .fill(themeManager.currentTheme.tintedBackgroundBase)
                            .overlay(
                                Rectangle()
                                    .fill(Color.white.opacity(0.1)) // lighten
                                    .blendMode(.screen)
                            )
                    )
                    .cornerRadius(8)
                    
                    Spacer().frame(height: 16)
                    
                    ShareLink(
                        item: URL(string: "https://ur.io/app?bonus=\(referralCode)")!,
                        subject: Text("URnetwork Referral Code"),
                        message: Text("All the content in the world from URnetwork"))
                    {
                        Text("Refer a friend")
                            .font(themeManager.currentTheme.toolbarTitleFont.bold())
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.urElectricBlue)
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .foregroundStyle(themeManager.currentTheme.textColor)
                    }
//                    .disabled(referralLinkViewModel.isLoading)
//                    .buttonStyle(.plain)
//                    .contentShape(Rectangle())
                    
//                    UrButton(text: "Refer a friend", action: {
//
//                    })
                    
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
////                Text("Step 2")
////                    .font(themeManager.currentTheme.titleCondensedFont)
//                
//                VStack(alignment: .leading) {
//                    
//                    Text("Refer some people and watch your free data go up.")
//                        .font(themeManager.currentTheme.toolbarTitleFont)
//                    
//                    Spacer().frame(height: 16)
//                    
//                    UrLabel(text: "Bonus referral code")
//                    
//                    Button(action: {
//                        
//                        copyToPasteboard(referralCode)
//                        
//                        // snackbar not showing above fullScreenCover
//                        snackbarManager.showSnackbar(message: "Bonus referral code copied to clipboard")
//                            
//                    }) {
//                        HStack {
//                            Text(referralCode)
//                                .font(themeManager.currentTheme.secondaryBodyFont)
//                                .foregroundColor(themeManager.currentTheme.textMutedColor)
//                                .lineLimit(1)
//                                .truncationMode(.tail)
//                            Spacer()
//                            Image(systemName: "document.on.document")
//                        }
//                        .foregroundColor(themeManager.currentTheme.textMutedColor)
//                        .padding(.vertical, 8)
//                        .padding(.horizontal, 16)
//                        .contentShape(Rectangle())
//                    }
//                    .buttonStyle(.plain)
//                    .background(
//                        Rectangle()
//                            .fill(themeManager.currentTheme.tintedBackgroundBase)
//                            .overlay(
//                                Rectangle()
//                                    .fill(Color.white.opacity(0.1)) // lighten
//                                    .blendMode(.screen)
//                            )
//                    )
//                    .cornerRadius(8)
//                    
//                    Spacer().frame(height: 16)
//                    
//                    ShareLink(
//                        item: URL(string: "https://ur.io/app?bonus=\(referralCode)")!,
//                        subject: Text("URnetwork Referral Code"),
//                        message: Text("All the content in the world from URnetwork"))
//                    {
//                        Text("Refer a friend")
//                            .font(themeManager.currentTheme.toolbarTitleFont.bold())
//                            .frame(maxWidth: .infinity)
//                            .padding()
//                            .background(.urElectricBlue)
//                            .cornerRadius(8)
//                            .contentShape(Rectangle())
//                            .foregroundStyle(themeManager.currentTheme.textColor)
//                    }
////                    .disabled(referralLinkViewModel.isLoading)
////                    .buttonStyle(.plain)
////                    .contentShape(Rectangle())
//                    
////                    UrButton(text: "Refer a friend", action: {
////                        
////                    })
//                    
//                    Spacer().frame(height: 16)
//                    
//                    Divider()
//                    
//                    Spacer().frame(height: 16)
//                    
//                    UrButton(text: "Get connected", action: {
//                        close()
//        //                dismiss()
//                    })
//                    
//                }
//                .padding()
//                .background(themeManager.currentTheme.tintedBackgroundBase)
//                .cornerRadius(16)
//                
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
    
    private func copyToPasteboard(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        #endif
    }
}

//#Preview {
//    ParticipateReferView(
//        close: {}
//    )
//}
