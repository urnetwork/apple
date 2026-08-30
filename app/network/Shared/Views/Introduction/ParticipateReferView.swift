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
        
        GeometryReader { proxy in
            
            ScrollView {
                
                VStack(alignment: .leading) {
                    
                    IntroIcon()
                    
                    Text("Refer friends".capitalized)
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 16)
                    
                    Text("When you refer a friend:")
                        .font(themeManager.currentTheme.bodyFontLarge)
                    
                    Spacer().frame(height: 16)
                    
                    IntroBulletPoint(text: "You get 3 GiB/day for life")

                    IntroBulletPoint(text: "Your friend gets 3 GiB/day for life")
                    
                    Spacer().frame(height: 16)
                    
                    VStack {
                     
                        HStack {
                            
                            Text("Refer friends")
                                .font(themeManager.currentTheme.toolbarTitleFont)
                            
                            Spacer()
                            
                            Text("\(totalReferrals)/20")
                                .font(themeManager.currentTheme.toolbarTitleFont)
                            
                        }
                        
                        Spacer().frame(height: 8)
                        
                        ReferBar(referralCount: totalReferrals)
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(16)
                    
                    Spacer().frame(height: 32)
                    
                    UrCard(cardLabel: "Your referral link") {
                        
                        Text("Refer some friends and watch your free data go up.")
                            .font(themeManager.currentTheme.toolbarTitleFont)
                        
                        Text("Your friends save too -- everyone wins.")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        
                        Spacer().frame(height: 16)
                        
                        UrLabel(text: "Bonus referral code")
                        
                        Button(action: {
                            
                            copyToPasteboard(referralCode)
                            
                            // snackbar not showing above fullScreenCover
                            snackbarManager.showSnackbar(message: String(localized: "Bonus referral code copied to clipboard"))
                            
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
                            item: String(localized: "Join me on URnetwork! Get the app and enter referral code \(referralCode) when you sign up."),
                            subject: Text("URnetwork Referral Code"))
                        {
                            Text("Refer a friend")
                                .font(themeManager.currentTheme.toolbarTitleFont.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .contentShape(Rectangle())
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.accent, lineWidth: 2)
                                        .cornerRadius(8)
                                )
                                .foregroundStyle(.accent)
                        }
                        
                    }
                    
                    Spacer().frame(minHeight: 32)
                    
                    UrButton(text: "Get connected", action: {
                        close()
                    })
                    .accessibilityIdentifier("acceptance.introduction.finish")
                    
                }
                .padding()
                .frame(minHeight: proxy.size.height)
                
            }
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
