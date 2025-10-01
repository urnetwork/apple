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
                            
                            Spacer().frame(height: 16)
                            
                            Text("URnetwork is the most local and most private network on the planet. With over 20x usable cities of other leading VPNs, and 100x fewer users per IP address. Unlock all the fun in the world and all the privacy without compromises.")
                                .font(themeManager.currentTheme.bodyFont)
                            
                            Spacer().frame(height: 32)
                            
                            /**
                             * Upgrade prompt
                             */
                            VStack(alignment: .leading) {
                                
                                Text("Upgrade")
                                    .font(themeManager.currentTheme.toolbarTitleFont)
                                
                                Spacer().frame(height: 4)
                                
                                Text("Get unlimited access to the full network and features on all platforms")
                                    .font(themeManager.currentTheme.bodyFont)
                                
                                Spacer().frame(height: 18)
                                
                                if let monthly = monthlySubscription, let yearly = yearlySubscription {
                                    
                                    ProductOptionCard(
                                        title: "Monthly",
                                        price: "\(monthly.displayPrice)/month",
                                        select: {
                                            selectedPaymentOption = .monthly
                                        },
                                        isSelected: selectedPaymentOption == .monthly
                                    )
                                    
                                    Spacer().frame(height: 18)
                                    
                                    ProductOptionCard(
                                        title: "Yearly",
                                        price: "\(yearly.displayPrice)/year",
                                        select: {
                                            selectedPaymentOption = .yearly
                                        },
                                        isSelected: selectedPaymentOption == .yearly
                                    )
                                    
                                    Spacer().frame(height: 18)
                                    
                                    UrButton(text: "Start 15 day free trial", action: {
                                        
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
                            .padding()
                            .background(themeManager.currentTheme.tintedBackgroundBase)
                            .cornerRadius(16)
                            
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
                            VStack(alignment: .leading) {
                                
                                Text("Participate in the network and get free access to the communtiy edition.")
                                    // .font(themeManager.currentTheme.bodyFont)
                                    .font(themeManager.currentTheme.toolbarTitleFont)
                                
                                Spacer().frame(height: 4)
                                
                                Text("URnetwork is powered by a patented protocol that keeps everyone safe and secure.")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                
                                Spacer().frame(height: 16)
                                
                                NavigationLink(destination: IntroductionUsageBar(
                                    close: close,
                                    totalReferrals: totalReferrals,
                                    referralCode: referralCode,
                                    meanReliabilityWeight: meanReliabilityWeight
                                )) {
                                    Text("Participate")
                                        .font(themeManager.currentTheme.toolbarTitleFont.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(.urElectricBlue)
                                        .cornerRadius(8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                            }
                            .padding()
                            .background(themeManager.currentTheme.tintedBackgroundBase)
                            .cornerRadius(16)
                            
                            
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
