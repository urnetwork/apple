//
//  ProviderColorCircle.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/5/25.
//

import SwiftUI

struct ProviderColorCircle: View {
    
    let color: Color
    let isStrongPrivacy: Bool
    
    init(color: Color, isStrongPrivacy: Bool) {
        self.color = color
        self.isStrongPrivacy = isStrongPrivacy
    }
    
    #if os(iOS)
//    let padding: CGFloat = 16
    let circleWidth: CGFloat = 40
    #elseif os(macOS)
//    let padding: CGFloat = 0
    let circleWidth: CGFloat = 30
    #endif
    
    var body: some View {
        
        ZStack {
         
            Circle()
                .frame(width: circleWidth, height: circleWidth)
                .foregroundColor(color)
            
            if isStrongPrivacy {
                Image("PrivacyGlasses")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            
        }
        .frame(width: circleWidth, height: circleWidth)
        
    }
}

#Preview {
    ProviderColorCircle(
        color: .urCoral,
        isStrongPrivacy: true
    )
}
