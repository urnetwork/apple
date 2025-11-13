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
    
    var monthlyProduct: Product?
    var yearlyProduct: Product?
    var purchase: (Product) -> Void
    var isPurchasing: Bool
    var purchaseSuccess: Bool
    var dismiss: () -> Void
    
    @State var selectedPaymentOption: PaymentOption = .yearly
    
    var body: some View {
        
        ZStack {
            
            if (purchaseSuccess) {
                
                PurchaseSuccessView(
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
                        
                        if let monthly = monthlyProduct, let yearly = yearlyProduct {
                            
                            VStack(alignment: .leading) {
                             
                                #if os(macOS)

                                HStack {
                                    Spacer()
                                    Button(action: {
                                        dismiss()
                                    }) {
                                        Image(systemName: "xmark")
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Spacer().frame(height: 8)

                                #endif

                                Text("Become a")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                HStack {
                                    Text("URnetwork Supporter")
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
                                
                                ProductOptionCard(
                                    price: "\(yearly.displayPrice)/year",
                                    select: {
                                        selectedPaymentOption = .yearly
                                    },
                                    isSelected: selectedPaymentOption == .yearly,
                                    includesFreeTrial: true,
                                    isMostPopular: true
                                )
                                
                                Spacer().frame(height: 18)
                                
                                ProductOptionCard(
                                    price: "\(monthly.displayPrice)/month",
                                    select: {
                                        selectedPaymentOption = .monthly
                                    },
                                    isSelected: selectedPaymentOption == .monthly,
                                    includesFreeTrial: false,
                                    isMostPopular: false
                                )
                                
                                Spacer().frame(minHeight: 18)
                                
                                VStack(alignment: .leading) {
                                    
                                    UrButton(text: "Join the movement", action: {
                                        if selectedPaymentOption == .monthly {
                                            purchase(monthly)
                                        } else {
                                            purchase(yearly)
                                        }
                                        
                                    })
                                    
                                    Spacer().frame(height: 18)

                                    HStack {
                                        Text("By subscribing, you agree to URnetwork's [Terms and Services](https://ur.io/terms) and [Privacy Policy](https://ur.io/privacy)")
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                                            .font(themeManager.currentTheme.secondaryBodyFont)
                                        
                                        Spacer()
                                    }
                                    
                                }
                                
                            }
                            
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
