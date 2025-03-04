//
//  ConnectButtonConnectedStateView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/28.
//

import SwiftUI

struct ConnectCanvasConnectedStateView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var canvasWidth: CGFloat
    var isActive: Bool
    var displayReconnectTunnel: Bool
    
    @State private var animateCircles = false
    @State private var colors: [Color] = [.urCoral, .urGreen, .urLightBlue, .urLightYellow, .accent]
    @State private var circleOffsets: [(initial: CGSize, final: CGSize)]
    
    @State private var warningOpacity: CGFloat = 0
    
    init(canvasWidth: CGFloat, isActive: Bool, displayReconnectTunnel: Bool) {
        self.canvasWidth = canvasWidth
        
        
        /**
         * we want to set up pairs of offsets
         * and then assign them randomly to circles
         * so there are different overlaps each time they animate in
         */
        let initialOffsets = [
            CGSize(width: -canvasWidth, height: -canvasWidth),
            CGSize(width: canvasWidth, height: -canvasWidth),
            CGSize(width: -canvasWidth, height: canvasWidth),
            CGSize(width: canvasWidth, height: canvasWidth),
            CGSize(width: canvasWidth, height: 0)
        ]
        
        let finalOffsets = [
            CGSize(width: -canvasWidth / 3.5, height: -canvasWidth / 4),
            CGSize(width: canvasWidth / 4, height: -canvasWidth / 3),
            CGSize(width: -canvasWidth / 3, height: canvasWidth / 4),
            CGSize(width: canvasWidth / 5, height: canvasWidth / 2.5),
            CGSize(width: canvasWidth / 4, height: 0)
        ]
        
        self._circleOffsets = State(initialValue: zip(initialOffsets, finalOffsets).map { ($0, $1) }.shuffled())
        
        self.isActive = isActive
        
        self.displayReconnectTunnel = displayReconnectTunnel
    }
    
    var body: some View {
        ZStack {
            
            ForEach(0..<5) { index in
                Circle()
                    .fill(self.colors[index])
                    .frame(width: 180, height: 180)
                    .offset(self.animateCircles
                            ? self.circleOffsets[index].final
                            : self.circleOffsets[index].initial
                    )
            }
            
            
            if displayReconnectTunnel {
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
        .frame(width: canvasWidth, height: canvasWidth)
        .clipped()
        .onChange(of: isActive) { newValue in
            
            if newValue == true {
                self.colors.shuffle()
                self.circleOffsets.shuffle()
            }
            
            withAnimation(.easeInOut(duration: 1)) {
                self.animateCircles = newValue
            }
        }
        .onChange(of: displayReconnectTunnel) { newValue in
            
            withAnimation(.easeInOut(duration: 1)) {
                self.animateCircles = !newValue
            }
            
        }
        .onAppear {
            
            // if closing out the app
            // then opening again, if the vpn connection is active
            // animate the circles back in
            if isActive {
                
                withAnimation(.easeInOut(duration: 1)) {
                    self.animateCircles = true
                }
                
            }
            
        }
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    ZStack {
        
        ConnectCanvasConnectedStateView(
            canvasWidth: 256,
            isActive: true,
            displayReconnectTunnel: false
        )
        
        Image("GlobeMask")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 256, height: 256)
        
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
}
