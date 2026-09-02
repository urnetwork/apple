//
//  ProvideControlModeList.swift
//  URnetwork
//
//  The provide mode as a list of choices with one short line under each
//  explaining what it does, for the onboarding page. Never needs none.
//

import SwiftUI

struct ProvideControlModeList: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ProvideControlMode.allCases) { mode in
                Button(action: {
                    deviceManager.provideControlMode = mode
                }) {
                    HStack(alignment: .center, spacing: 12) {
                        let selected = deviceManager.provideControlMode == mode
                        Circle()
                            .fill(selected ? themeManager.currentTheme.accentColor : Color.clear)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle().stroke(
                                    selected ? themeManager.currentTheme.accentColor : themeManager.currentTheme.textMutedColor,
                                    lineWidth: 2
                                )
                            )
                            .padding(.leading, 4)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provideControlModeLabel(mode))
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            if let description = Self.description(mode) {
                                Text(description)
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(deviceManager.provideControlMode == mode ? .isSelected : [])
            }
        }
    }

    /// One short line explaining what a mode does; Never needs none.
    static func description(_ mode: ProvideControlMode) -> LocalizedStringKey? {
        switch mode {
        case .Auto:
            return "Provides to everyone while you're connected, otherwise only to your own devices."
        case .Always:
            return "Provides to everyone whenever the app is running."
        case .Network:
            return "Provides only to your own network's devices."
        case .Never:
            return nil
        }
    }
}
