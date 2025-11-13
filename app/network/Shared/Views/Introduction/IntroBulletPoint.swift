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
        
            HStack {
                
                Circle().foregroundStyle(.urGreen).frame(width: 12, height: 12)
                
                Spacer().frame(width: 16)
             
                Text(text)
                    .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
                
            }
            
            Spacer().frame(height: 16)
            
        }
        
    }
}

#Preview {
    IntroBulletPoint(text: "Hello")
}
