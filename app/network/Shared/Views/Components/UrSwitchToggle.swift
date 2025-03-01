//
//  UrSwitchToggle.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/26.
//

import SwiftUI

struct UrSwitchToggleStyle: ToggleStyle {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack {
                // track
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isOn ? themeManager.currentTheme.accentColor : Color.clear)
                    .frame(width: 40, height: 22)
                    .overlay(
                        // track border
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(themeManager.currentTheme.accentColor, lineWidth: 3)
                    )
                    .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
                
                // circle
                Circle()
                    .fill(themeManager.currentTheme.backgroundColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        // circle border
                        Circle()
                            .stroke(
                                configuration.isOn ? themeManager.currentTheme.backgroundColor : themeManager.currentTheme.accentColor,
                                lineWidth: 3
                            )
                            .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
                    )
                    .offset(x: configuration.isOn ? 11 : -9)
                    .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
            }
            .onTapGesture {
                withAnimation {
                    configuration.isOn.toggle()
                }
            }
        }
    }
    
}

struct UrSwitchToggle<Label: View>: View {
    
    @Binding var isOn: Bool
    var isEnabled: Bool = true
    var label: () -> Label

    var body: some View {
        Toggle(isOn: $isOn) {
            label()
        }
        .toggleStyle(UrSwitchToggleStyle())
        .disabled(!isEnabled)
    }
}

#Preview {
    
    UrSwitchToggle(
        isOn: .constant(false)
    ) {
        Text("Hello world")
    }
}
