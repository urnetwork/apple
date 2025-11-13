//
//  IntroductionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
import StoreKit

struct IntroductionView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectViewModel: ConnectViewModel
    
    let close: () -> Void
    let totalReferrals: Int
    let referralCode: String
    let meanReliabilityWeight: Double
    
    private var monthlySubscription: Product? {
        return subscriptionManager.monthlySubscription
    }
    
    private var yearlySubscription: Product? {
        return subscriptionManager.yearlySubscription
    }
    
    @State var selectedPaymentOption: PaymentOption = .yearly
    
    var body: some View {
        
        ZStack {
            
            if (subscriptionManager.purchaseSuccess) {
                
                PurchaseSuccessView(dismiss: close)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                
            } else {
        
                NavigationStack {
                    
                    ScrollView {
                        
                        VStack(alignment: .leading) {
                            
                            Text("Welcome to URnetwork")
                                .font(themeManager.currentTheme.titleFont)
                            
                            Spacer().frame(height: 8)
                            
                            Text("URnetwork is the most local and most private network on the planet.")
                                .font(themeManager.currentTheme.bodyFontLarge)
                            
                            Spacer().frame(height: 32)
                            
                            // points
                            IntroBulletPoint(text: "100% open source and transparent")
                            
                            IntroBulletPoint(text: "Lowest user/IP ratio to access content")
                            
                            IntroBulletPoint(text: "Trusted by over 100,000 private networks")
                            
                            Spacer().frame(height: 24)
                            
                            /**
                             * Upgrade prompt
                             */
                            VStack(alignment: .leading) {
                                
                                if let monthly = monthlySubscription, let yearly = yearlySubscription {
                                    
                                    ProductOptionCard(
                                        price: "\(yearly.displayPrice) Annual (Save 33%)",
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
                                    
                                    Spacer().frame(height: 18)
                                    
                                    UrButton(text: "Start 2 week free trial", action: {
                                        
                                        let product = selectedPaymentOption == .monthly ? monthly : yearly
                                        
                                        let initiallyConnected = deviceManager.device?.getConnected() ?? false
                                        
#if os(macOS)
                                        // purchase fails in mac app store if vpn is connected
                                        if (initiallyConnected) {
                                            connectViewModel.disconnect()
                                        }
#endif
                                        
                                        Task {
                                            do {
                                                try await subscriptionManager.purchase(
                                                    product: product,
                                                    onSuccess: {
                                                        subscriptionBalanceViewModel.setCurrentPlan(.supporter)
                                                    }
                                                )
                                                
                                            } catch(let error) {
                                                print("error making purchase: \(error)")
                                            }
                                            
#if os(macOS)
                                            if (initiallyConnected) {
                                                connectViewModel.connect()
                                            }
#endif
                                            
                                        }
                                        
                                        
                                        
                                    })
                                } else {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                }
                                
                            }
                            
                            Spacer().frame(height: 16)
                            
                            HStack {
                                Spacer()
                                Text("or")
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                Spacer()
                            }
                            
                            Spacer().frame(height: 16)
                            
                            
                            
                            /**
                             * Participate prompt
                             */
                                
                            NavigationLink(destination: IntroductionUsageBar(
                                close: close,
                                totalReferrals: totalReferrals,
                                referralCode: referralCode,
                                meanReliabilityWeight: meanReliabilityWeight
                            )) {
                                VStack(alignment: .center) {
                                    Text("Community Edition")
                                        .font(themeManager.currentTheme.toolbarTitleFont)
                                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                    
                                    Spacer().frame(height: 4)
                                    
                                    
                                    Text("Participate in the network and get free access to the community edition.")
                                        .font(Font.custom("PP NeueBit", size: 18).weight(.bold))
                                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(themeManager.currentTheme.textFaintColor, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            
                            
                            Spacer().frame(height: 32)
                            
                            HStack(alignment: .center) {
                                Text("""
                                URnetwork is powered by a patented protocol
                                that keeps everyone safe and secure.
                                """)
                                    .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)

                            Spacer()
                        }
                        .padding()
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: close) {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close")
                        }
                    }
                }
                
            }
            
        }
        .animation(.easeIn(duration: 0.25), value: subscriptionManager.purchaseSuccess)
        
    }
}

#Preview {
    IntroductionView(
        close: {},
        totalReferrals: 4,
        referralCode: "ABC123",
        meanReliabilityWeight: 2.0
    )
}
