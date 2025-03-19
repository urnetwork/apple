//
//  ConnectProcessingSubscriptionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/19.
//

import SwiftUI

struct ConnectProcessingSubscriptionView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack {
            Image(systemName: "hourglass")
                .font(.system(size: 32))
                .foregroundColor(themeManager.currentTheme.textFaintColor)
        }
        .padding(.horizontal, 4)
    }
}

#Preview {
    ConnectProcessingSubscriptionView()
}
