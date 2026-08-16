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

/// Shared disclosure for the intentional routes that bypass the kill switch.
/// Keeping the copy and interaction in one component makes the exception hard
/// to omit when the setting is presented on another Apple form factor.
struct KillSwitchLabel: View {

    @EnvironmentObject var themeManager: ThemeManager
    @State private var isPresentingException = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Kill switch")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            Button {
                isPresentingException = true
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show kill switch exception")
        }
        .alert("Kill switch exception", isPresented: $isPresentingException) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("While the VPN is connected, IPv6 is not routed through URnetwork and may use your local network, even when the kill switch is on. Outbound SMTP on TCP port 25 also bypasses the VPN. These exceptions may expose your local public IP to those destinations. SMTP on ports 465 and 587 stays in the VPN and must establish TLS.")
        }
    }
}

#Preview {
    
    UrSwitchToggle(
        isOn: .constant(false)
    ) {
        Text("Hello world")
    }
}
