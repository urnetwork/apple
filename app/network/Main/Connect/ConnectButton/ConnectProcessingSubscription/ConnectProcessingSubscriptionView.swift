//
//  ConnectProcessingSubscriptionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/19.
//

import SwiftUI

struct ConnectProcessingSubscriptionView: View {
    
    @EnvironmentObject var themeManager: ThemeManager

    @State private var opacity: CGFloat = 0
    
    var body: some View {
        VStack {
            Image(systemName: "hourglass")
                .font(.system(size: 32))
                .foregroundColor(themeManager.currentTheme.textFaintColor)
                .opacity(opacity)
        }
        .padding(.horizontal, 4)
        .onAppear {
            // Delay the animation by 500ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    opacity = 1
                }
            }
        }
        .onDisappear {
            opacity = 0
        }
    }
}

#Preview {
    ConnectProcessingSubscriptionView()
}
