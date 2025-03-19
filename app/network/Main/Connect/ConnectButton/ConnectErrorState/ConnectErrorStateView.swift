//
//  ConnectErrorStateView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/03/18.
//

import SwiftUI

struct ConnectErrorStateView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var warningOpacity: CGFloat = 0
    
    var body: some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(themeManager.currentTheme.textFaintColor)
                .opacity(warningOpacity)
        }
        .padding(.horizontal, 4)
        .onAppear {
            // Delay the animation by 500ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    warningOpacity = 1
                }
            }
        }
        .onDisappear {
            warningOpacity = 0
        }
    }
}

#Preview {
    ConnectErrorStateView()
}
