//
//  PaymentsList.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/19.
//

import SwiftUI
import URnetworkSdk

struct PaymentsList: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    var payments: [SdkAccountPayment]
    var navigate: (AccountNavigationPath) -> Void
    
    private var currentDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date())
    }

    
    var body: some View {
        
        VStack {
            
            if !payments.isEmpty {
             
                HStack {
                    Text("Earnings")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        
                    
                    Spacer()
                }
                .padding(.horizontal)
                
                ForEach(payments, id: \.paymentId) { payment in
                    
                    Divider()
                    
                    HStack {
                        
                        if payment.completed {
                            Image("ur.symbols.check.circle")
                                .frame(width: 48, height: 48)
                                .background(themeManager.currentTheme.tintedBackgroundBase)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "timer")
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .frame(width: 48, height: 48)
                                .background(themeManager.currentTheme.tintedBackgroundBase)
                                .clipShape(Circle())
                        }
                        
                        Spacer().frame(width: 16)
                        
                        VStack {
                            
                            HStack {
                                if payment.completed {
                                    Text("+\(String(format: "%.2f", payment.tokenAmount)) USDC")
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)
                                } else {
                                    Text("Pending: \(String(format: "%.2f", Double(payment.payoutByteCount) / 1_000_000)) MB provided")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                }
                                
                                Spacer()
                            }
                                
                            
                            HStack {
                                if let completeTime = payment.completeTime {
                                    
                                    Text(completeTime.format("Jan 2"))
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                } else {
                                    Text(currentDateFormatted)
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                }
                                
                                Spacer()
                            }
                            
                        }
                        
                        Spacer()
                        
                        Image("ur.symbols.caret.right")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        
//                        Text("***\(payment.walletAddress.suffix(6))")
//                            .font(themeManager.currentTheme.secondaryBodyFont)
//                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        
                    }
                    .padding(.horizontal)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navigate(.payout(payment: payment, accountPoint: nil))
                    }
                    
                }
                
            }
            
        }
        
    }
}

#Preview {
    PaymentsList(
        payments: [],
        navigate: {_ in},
    )
}
