//
//  ProvideModeRow.swift
//  URnetwork
//
//  The "Provide mode · <current>" row: the settings picker's indicator and
//  label (ProvideModeIndicator, IntroductionParticipateSettingsView.swift)
//  with the current mode, shared by the provider statistics section so the
//  stats and earnings screens render the mode exactly like settings.
//

import SwiftUI
import URnetworkSdk

/// "Provide mode · <current mode>": the settings picker's indicator and label
/// with the current mode beside it. The whole row opens the settings where
/// the mode is changed.
struct ProvideModeRow: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProvideModeIndicator()
                Text("Provide mode")
                    .font(themeManager.currentTheme.bodyFont)
                Spacer()
                Text(provideControlModeLabel(deviceManager.provideControlMode))
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
