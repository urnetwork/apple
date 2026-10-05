//
//  ProvidePowerModePicker.swift
//  URnetwork
//
//  "When on battery": what providing does while this device runs on battery
//  (P077), next to the other provide settings. Keep providing, pause in Low
//  Power Mode (the default), or pause until charging.
//

import SwiftUI

/// The "When on battery" picker, bound to the user's choice.
struct ProvidePowerModePicker: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var providePowerStore: ProvidePowerStore

    var body: some View {
        Picker(selection: $providePowerStore.mode) {
            ForEach(ProvidePowerMode.allCases) { mode in
                Text(mode.label)
                    .font(themeManager.currentTheme.bodyFont)
            }
        } label: {
            Text("When on battery")
                .font(themeManager.currentTheme.bodyFont)
        }
        .accentColor(themeManager.currentTheme.textColor)
    }
}
