//
//  ConnectButtonDisconnectedStateView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/28.
//

import SwiftUI

struct ConnectCanvasDisconnectedStateView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var pulseScale: CGFloat = 1
    // @State private var pulseOpacity: Double = 1
    
    @State var showAnimation: Bool = false
    
    var body: some View {
        
        ZStack {
            
            if showAnimation {
             
                // pulsing blue circle
                ZStack(alignment: .center) {
                 
                    Circle()
                        .fill(Color.urElectricBlue)
                        .frame(width: 56, height: 56)
                        .scaleEffect(pulseScale)
                        .opacity(1.5 - pulseScale)
                        .animation(
                            Animation.easeOut(duration: 1.5)
                                .repeatForever(autoreverses: false),
                            value: pulseScale
                        )
                    
                }
                .frame(width: 84, height: 84, alignment: .center)
                .contentShape(Rectangle())
                .onAppear {
                    pulseScale = 1.5
                }
                
            }
            
            
            Circle()
                .stroke(Color.urElectricBlue, lineWidth: 4)
                .frame(width: 52, height: 52)
            
            Circle()
                .stroke(themeManager.currentTheme.tintedBackgroundBase, lineWidth: 2)
                .frame(width: 50, height: 50)
            
            Circle()
                .fill(Color.urElectricBlue)
                .frame(width: 48, height: 48)
            
            
//            VStack {
//                Text("Tap to connect")
//                    .font(Font.custom("PP NeueBit", size: 20))
//                    .foregroundColor(themeManager.currentTheme.textColor)
//                
//                Spacer().frame(height: 120)
//            }
        }
        .frame(width: 120, height: 120)
        .onAppear {
            /**
             * https://stackoverflow.com/a/65610266/3703043
             * Wait for the view to fully render before showing the animated element.
             * This prevents unpredictable shift in animated circle position
             */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                showAnimation = true
            }
        }
    }

}

#Preview {
    
    let themeManager = ThemeManager.shared
    
    VStack {
        ConnectCanvasDisconnectedStateView()
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
}
