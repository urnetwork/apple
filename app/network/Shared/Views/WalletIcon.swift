//
//  WalletIcon.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/19.
//

import SwiftUI

struct WalletIcon: View {
    var blockchain: String
    var size: CGFloat = 48
    
    var backgroundGradient: Gradient {

        if blockchain == "SOL" {
            return Gradient(colors: [Color(hex: "#9945FF"), Color(hex: "#14F195")])
        }

        if blockchain == "TAO" {
            return Gradient(colors: [Color(hex: "#1C1C1C"), Color(hex: "#3A3A3A")])
        }

        // otherwise, POLY
        return Gradient(colors: [Color(hex: "#8A46FF"), Color(hex: "#6E38CC")])
    }

    var logoPath: String {

        if blockchain == "SOL" {
            return "solana.logo"
        }

        // otherwise, POLY
        return "polygon.logo"

    }

    var logoWidth: CGFloat {

        if blockchain == "SOL" {
            return size / 2
        }

        // otherwise, POLY
        return size

    }

    var body: some View {

        ZStack {
            LinearGradient(gradient: backgroundGradient, startPoint: .top, endPoint: .bottom)
                .clipShape(
                    Circle()
                )

            if blockchain == "TAO" {
                // the bittensor tau mark
                Text("τ")
                    .font(.system(size: size / 2, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Image(logoPath)
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoWidth, height: logoWidth)
            }
        }
        .frame(width: size, height: size)

    }
}

#Preview {
    WalletIcon(
        blockchain: "SOL"
    )
}
