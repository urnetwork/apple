//
//  UrCard.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 11/13/25.
//

import SwiftUI

struct UrCard<Content: View>: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    let cardLabel: LocalizedStringKey?
    
    let content: Content

    init(cardLabel: LocalizedStringKey, @ViewBuilder _ content: () -> Content) {
        self.cardLabel = cardLabel
        self.content = content()
    }

    init(@ViewBuilder _ content: () -> Content) {
        self.cardLabel = nil
        self.content = content()
    }
    
    var body: some View {
        
        VStack {
            if let cardLabel {
                HStack {
                    Text(cardLabel)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .font(Font.custom("PP NeueBit", size: 22).bold())

                    Spacer()
                }
                .padding(.horizontal)
            }
            
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)
        }
        
    }
}

#Preview {
    UrCard {
        Text("hello world")
    }
}
