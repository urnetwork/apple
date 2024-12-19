//
//  WalletView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/15.
//

import SwiftUI
import URnetworkSdk

struct WalletView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    // @EnvironmentObject var accountPaymentsViewModel: AccountPaymentsViewModel
    
    var wallet: SdkAccountWallet
    let isCircleWallet: Bool
    let isPayoutWallet: Bool
    let payments: [SdkAccountPayment]
    
    var walletName: String {
        
        if isCircleWallet {
            return "Circle"
        }
        
        if wallet.blockchain == "SOL" {
            return "Solana"
        }
        
        // otherwise, POLY
        return "Polygon"
        
    }
    
    init(wallet: SdkAccountWallet, payoutWalletId: SdkId?, payments: [SdkAccountPayment]) {
        self.wallet = wallet
        self.isCircleWallet = wallet.walletType == SdkWalletTypeCircleUserControlled
        self.isPayoutWallet = payoutWalletId?.cmp(wallet.walletId) == 0
        self.payments = payments
    }
    
    var body: some View {
        ScrollView {
         
            VStack {
                
                HStack {
                    
                    VStack(alignment: .leading) {
                        WalletIcon(
                            isCircleWallet: isCircleWallet, blockchain: wallet.blockchain
                        )
                    }
                    
                    Spacer().frame(width: 16)
                    
                    VStack(alignment: .leading) {
                        
                        Text("\(walletName) wallet")
                            .font(themeManager.currentTheme.secondaryTitleFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        
                        if !isCircleWallet {
                            Text(wallet.obscuredWalletAddress())
                                .font(themeManager.currentTheme.toolbarTitleFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                        
                    }
                    
                    Spacer()
                    
                }
                
                // Commented out for testing
                // if isCircleWallet {
                    
                    Spacer().frame(height: 16)
                    
                    VStack {
                     
                        HStack {
                            
                            UrLabel(text: "Balance")
                            
                            Spacer()
                            
                        }
                        
                        HStack(alignment: .firstTextBaseline) {
                            
                            // TODO: populate circle wallet balance
                            Text("$1.23")
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                            Text("USDC")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                            
                            Spacer()
                            
                        }
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(12)
                    
                // }
                
                Spacer().frame(height: 16)
                
                
                /**
                 * Actions
                 */
                VStack {
                    
                    if !isPayoutWallet {
                        
                        UrButton(text: "Make default", action: {})
                        
                        Spacer().frame(height: 8)
                        
                    }
                    
                    if isCircleWallet {
                        
                        UrButton(text: "Transfer funds", action: {})
                        Spacer().frame(height: 8)
                        
                    } else {
                        
                        UrButton(
                            text: "Remove wallet",
                            action: {},
                            style: .outlineSecondary
                        )
                        
                    }
                    
                }
                
                Spacer().frame(height: 32)
                
                /**
                 * Payouts list
                 */
                PaymentsList(
                    payments: payments
                )
                
                Spacer()
                
            }
            .padding()
            
        }
    }
}

#Preview {
    WalletView(
        wallet: SdkAccountWallet(),
        payoutWalletId: nil,
        payments: []
    )
}
