//
//  ExtenderMeasurementsRow.swift
//  URnetwork
//
//  The lag.dev speed tests switch, under the Extender row of the Connections
//  card (lag.dev/PLAN.md C4, decision 18). macOS only; iOS runs no role.
//

#if os(macOS)
import SwiftUI

/// The speed tests switch: whether this device's extender role serves
/// lag.dev's measurement API, so people testing their connection there can
/// measure to it. On by default; off stops the API at once and has the
/// operator withdraw the device's measurement name. It draws beside the
/// Extender row, so only while the device reports the role supported: hidden,
/// never disabled.
struct ExtenderMeasurementsRow: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    /// the Extender row's dot and the gap after it (`ExtenderProvideRow`), so
    /// this title starts under the Extender title
    private static let inset: CGFloat = ExtenderProvideIndicator.size + 8

    var body: some View {
        if deviceManager.extenderProvideDisplay.visible {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $deviceManager.measurementsEnabled) {
                    HStack {
                        Text("lag.dev speed tests")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        Spacer()
                    }
                }
                // the native switch, trailing, as the Extender row's
                .toggleStyle(.switch)

                Text("Let people testing their connection on lag.dev measure latency, download and upload to this device. Tests use some of your bandwidth while they run.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Self.inset)
        }
    }
}
#endif
