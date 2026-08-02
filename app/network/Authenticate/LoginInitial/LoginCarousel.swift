//
//  LoginCarousel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/27.
//

import SwiftUI
import Combine

struct LoginCarousel: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.presentationActive) private var presentationActive
    
    private let images = ["LoginCarousel1", "LoginCarousel2", "LoginCarousel3"]
    @State private var currentOpacity = 1.0
    @State private var nextOpacity = 0.0
    @State private var currentIndex = 0
    @State private var nextIndex = 1
    @State private var cancellables = Set<AnyCancellable>()
    
    private static let slide1Text = """
        See all the 
        world's content
        """
    private static let slide2Text = """
        Stay
        completely
        private and
        anonymous
        """
    private static let slide3Text = """
        Build the 
        internet the 
        right way
        """
    private static let slideBottomText = "with URnetwork."
    
    @State private var textOffset: CGFloat = 0
    @State private var textOpacity = 1.0
    @State private var bottomTextOffset: CGFloat = 0
    @State private var bottomTextOpacity = 1.0
    
    private var currentSlideText: String {
        switch currentIndex {
        case 0: return LoginCarousel.slide1Text
        case 1: return LoginCarousel.slide2Text
        default: return LoginCarousel.slide3Text
        }
    }
    
    
    var body: some View {
        
        ZStack {
        
            ZStack {
                
                // Current Image
                Image(images[currentIndex])
                    .resizable()
                    .scaledToFill()
                    .frame(width: 256, height: 256)
                    .opacity(currentOpacity)
                
                // Next Image
                Image(images[nextIndex])
                    .resizable()
                    .scaledToFill()
                    .frame(width: 256, height: 256)
                    .opacity(nextOpacity)
            }
            .frame(width: 256, height: 256)
            .mask {
                Image("ur.symbols.globe")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .clipped()
            
            VStack {
                Text(currentSlideText)
                    .id("slideText-\(currentIndex)")
                    .font(themeManager.currentTheme.titleFont)
                    .multilineTextAlignment(.center)
                    .offset(y: textOffset)
                    .opacity(textOpacity)
                    .animation(.easeOut(duration: 0.5), value: textOffset)
                    .animation(.easeOut(duration: 0.3), value: textOpacity)
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                // "with URnetwork"
                Text(LoginCarousel.slideBottomText)
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(y: bottomTextOffset)
                    .opacity(bottomTextOpacity)
                    .animation(.easeOut(duration: 0.4), value: bottomTextOffset)
                    .animation(.easeOut(duration: 0.2), value: bottomTextOpacity)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            
        }
        .onAppear {
            startCarousel()
        }
        .onChange(of: presentationActive) { active in
            if active {
                startCarousel()
            } else {
                stopCarousel()
            }
        }
        .onDisappear {
            stopCarousel()
        }
        
    }
    
    private func startCarousel() {

        // cancel existing timers
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        guard PresentationWorkState.shouldRun(
            presentationActive: presentationActive
        ) else {
            return
        }
        
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                guard presentationActive else {
                    return
                }
                self.animateTextOut()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard presentationActive else {
                        return
                    }
                    self.transitionToNextSlide()
                }
            }
            .store(in: &cancellables)
        
    }
    
    private func stopCarousel() {
        // remove all active publishers
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
    
    private func transitionToNextSlide() {
        guard presentationActive else {
            return
        }

        // animate out the image
        withAnimation(.easeInOut(duration: 0.7)) {
            currentOpacity = 0
            nextOpacity = 1
        }
        
        // state updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard presentationActive else {
                return
            }
            currentIndex = nextIndex
            nextIndex = (nextIndex + 1) % images.count
            currentOpacity = 1
            nextOpacity = 0
            self.animateTextIn()
        }
    }
    
    func animateTextIn() {
        // Reset states
        textOffset = 100
        textOpacity = 0
        bottomTextOffset = 40
        bottomTextOpacity = 0
        
        // animate the text in
        withAnimation(.easeOut(duration: 0.5)) {
            textOffset = 0
            textOpacity = 1
        }

        // animate the bottom text in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard presentationActive else {
                return
            }
            withAnimation(.easeOut(duration: 0.4)) {
                bottomTextOffset = 0
                bottomTextOpacity = 1
            }
        }
    }
    
    private func animateTextOut() {
        withAnimation(.easeIn(duration: 0.5)) {
            textOffset = -100 // Move up and out
            textOpacity = 0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard presentationActive else {
                return
            }
            withAnimation(.easeIn(duration: 0.4)) {
                bottomTextOffset = -70 // Move up and out
                bottomTextOpacity = 0
            }
        }
    }
}

#Preview {
    
    let themeManager = ThemeManager.shared
    
    VStack {
        LoginCarousel()
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
}
