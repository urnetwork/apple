//
//  IntroBulletPoint.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 11/11/25.
//

import SwiftUI

struct IntroBulletPoint: View {
    
    var text: LocalizedStringKey
    
    var body: some View {
        
        VStack {
        
            // the dot sits on the first line, and a bullet that wraps stays left-aligned
            HStack(alignment: .top) {
                
                Circle().foregroundStyle(.urGreen).frame(width: 12, height: 12)
                    .padding(.top, 6)
                
                Spacer().frame(width: 16)
             
                Text(text)
                    .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
                
            }
            
            Spacer().frame(height: 16)
            
        }
        
    }
}

#Preview {
    IntroBulletPoint(text: "Hello")
}
