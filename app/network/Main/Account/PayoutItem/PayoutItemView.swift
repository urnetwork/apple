//
//  PayoutItemView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 6/17/25.
//

import SwiftUI
import URnetworkSdk

struct PayoutItemView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var navigate: (AccountNavigationPath) -> Void
    var payment: SdkAccountPayment
    var accountPointsViewModel: AccountPointsViewModel
    var isMultiplierTokenHolder: Bool
    
    var body: some View {
        
        VStack {
            
            
            HStack {
                if let completedAt = payment.completeTime {
                    Text("\(completedAt.format("Jan 2, 2006")) Payout")
                        .font(themeManager.currentTheme.titleCondensedFont)
                } else {
                    Text("Payment Pending")
                        .font(themeManager.currentTheme.titleCondensedFont)
                }
                
                Spacer()
            }
            
            AccountPointsBreakdown(
                isSeekerOrSagaHolder: isMultiplierTokenHolder,
                netPoints: accountPointsViewModel.netPointsByPaymentId(payment.paymentId),
                payoutPoints: accountPointsViewModel.payoutPointsByPaymentId(payment.paymentId),
                referralPoints: accountPointsViewModel.referralPointsByPaymentId(payment.paymentId),
                multiplierPoints: accountPointsViewModel.multiplierPointsByPaymentId(payment.paymentId)
            )
            
            Spacer().frame(height: 24)
            
            if (payment.completed) {
                
                HStack {
                    VStack(alignment: .leading) {
                        UrLabel(text: "Amount")
                        Text("\(payment.tokenAmount) \(payment.tokenType)")
                            .font(themeManager.currentTheme.bodyFont)
                    }
                    
                    Spacer()
                }
                
                Spacer().frame(height: 12)
                
                HStack {
                    VStack(alignment: .leading) {
                        UrLabel(text: "Wallet Address")
                        Text("\(payment.walletAddress)")
                            .font(themeManager.currentTheme.bodyFont)
                    }
                    
                    Spacer()
                }
                
                Spacer().frame(height: 12)
                 
                HStack {
                    VStack(alignment: .leading) {
                        UrLabel(text: "Transaction")
                        
                        
                        Link(
                            destination: payment.blockchain == "SOL"
                                ? URL(string: "https://solscan.io/tx/\(payment.txHash)")!
                                : URL(string: "https://polygonscan.com/tx/\(payment.txHash)")!
                        ) {
                            Text("\(payment.txHash)")
                                .multilineTextAlignment(.leading)
                        }
                        .font(themeManager.currentTheme.bodyFont)
                    }
                    
                    Spacer()
                }
                
            } else {
                
                // pending icon
                VStack {
                    
                    Image(systemName: "timer")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                
            }
            
            Spacer()
            
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

//#Preview {
//    PayoutItemView()
//}
