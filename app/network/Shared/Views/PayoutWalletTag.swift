//
//  PayoutWalletTag.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/19.
//

import SwiftUI

struct PayoutWalletTag: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var isPayoutWallet: Bool
    
    var body: some View {
        HStack {
            if isPayoutWallet {
                Text("Default")
                    .textCase(.uppercase)
                    .font(Font.custom("PP NeueBit", size: 16).weight(.bold))
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
        .padding(6)
        .background(isPayoutWallet ? .white.opacity(0.04) : .clear)
        .cornerRadius(6)
    }
}

#Preview {
    PayoutWalletTag(
        isPayoutWallet: true
    )
}
