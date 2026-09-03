//
//  ProvideControlPicker.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/26/25.
//

import SwiftUI
import URnetworkSdk

struct ProvideControlPicker: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    

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

                    ProvideModeIndicator()

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
