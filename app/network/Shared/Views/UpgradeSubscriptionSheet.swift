//
//  UpgradeSubscriptionSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import SwiftUI
import StoreKit

struct UpgradeSubscriptionSheet: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var subscriptionProduct: Product?
    var purchase: (Product) -> Void
    var isPurchasing: Bool
    var purchaseSuccess: Bool
    var dismiss: () -> Void
    
    var body: some View {
        
        ZStack {
            
            if (purchaseSuccess) {
                
                UpgradePurchaseSuccessView(
                    dismiss: dismiss
                )
                .transition(.opacity)
                .frame(maxWidth: .infinity)
                
            } else {
                
                VStack {
                    
                    if (isPurchasing) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        
                        if let product = subscriptionProduct {
                            
                            HStack {
                                
                                Text("Become a")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                                Spacer()
                                
                                Text("\(product.displayPrice)/month")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                
                            }
                            
                            HStack {
                                Text(product.displayName)
                                    .font(themeManager.currentTheme.titleFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                                Spacer()
                            }
                            
                            Spacer().frame(height: 24)
                            
                            HStack {
                                Text("Support us in building a new kind of network that gives instead of takes.")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                
                                Spacer()
                            }
                            
                            Spacer().frame(height: 18)
                            
                            HStack {
                                
                                Text("You’ll unlock even faster speeds, and first dibs on new features like robust anti-censorship measures and data control.")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                
                                Spacer()
                                
                            }
                            
                            Spacer().frame(height: 18)
                            
                            HStack {
                                Text("By subscribing, you agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                
                                Spacer()
                            }
                            
                            Spacer()
                            
                            UrButton(text: "Join the movement", action: {
                                // subscriptionManager.purchase(product: product)
                                purchase(product)
                            })
                            
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        }
                        
                    }
                    
                }
                .transition(.opacity)
                .padding()
                .frame(maxWidth: .infinity)
                
            }
            
        }
        .frame(maxWidth: .infinity)
        .animation(.easeIn(duration: 0.25), value: purchaseSuccess)
            
    }
}

struct UpgradePurchaseSuccessView: View {
    
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

//#Preview {
//    
//    let themeManager = ThemeManager.shared
//    
//    let mockProduct = MockSKProduct(
//        localizedTitle: "URnetwork Supporter",
//        localizedDescription: "Support us in building a new kind of network that gives instead of takes.",
//        price: 5.00,
//        priceLocale: Locale(identifier: "en_US")
//    )
//    
//    VStack {
//        UpgradeSubscriptionSheet(
//            subscriptionProduct: mockProduct,
//            purchase: {_ in}
//        )
//    }
//    .environmentObject(themeManager)
//    .background(themeManager.currentTheme.backgroundColor)
//    .frame(maxWidth: .infinity, maxHeight: .infinity)
//    
//}
