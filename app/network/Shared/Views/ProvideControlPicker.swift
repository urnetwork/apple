//
//  ProvideControlPicker.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/26/25.
//

import SwiftUI

struct ProvideControlPicker: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    // Computed property for indicator color
    private var provideIndicatorColor: Color {
        if !deviceManager.provideEnabled {
            return .urCoral
        } else if deviceManager.providePaused {
            return .urYellow
        } else {
            return .urGreen
        }
    }
    
    var body: some View {

        LabeledContent{
            Picker(
                "",
                selection: $deviceManager.provideControlMode
            ) {
                ForEach(ProvideControlMode.allCases) { mode in
                    Text(provideControlModeLabel(mode))
                        .font(themeManager.currentTheme.bodyFont)
                    
                }
            }} label: {
                HStack {
    
                    Circle()
                        .frame(width: 8, height: 8)
                        .foregroundColor(provideIndicatorColor)
    
                    Text("Provide mode")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer()
    
                }
            }

        }
    
}

#Preview {
    ProvideControlPicker(
//        provideEnabled: true,
//        providePaused: false
    )
}
