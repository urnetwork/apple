//
//  ExtenderPortMappingRow.swift
//  URnetwork
//
//  The router port mapping switch, under the speed tests switch of the
//  Connections card (EXTENDER.md S8). macOS only; iOS runs no role.
//

#if os(macOS)
import SwiftUI

/// The router port mapping switch: whether this device's extender role asks
/// the router, by UPnP, NAT-PMP or PCP, to forward its ports -- TCP and UDP
/// 443 and UDP 4053 -- to this device, which opens them on the router. Off by
/// default on every app (owner, 2026-11-11); off removes what the router
/// forwards. It draws beside the Extender row, so only while the device
/// reports the role supported: hidden, never disabled.
struct ExtenderPortMappingRow: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    /// the Extender row's dot and the gap after it (`ExtenderProvideRow`), so
    /// this title starts under the Extender title
    private static let inset: CGFloat = ExtenderProvideIndicator.size + 8

    var body: some View {
        if deviceManager.extenderProvideDisplay.visible {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $deviceManager.extenderPortMapping) {
                    HStack {
                        Text("Open a port on my router")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        Spacer()
                    }
                }
                // the native switch, trailing, as the Extender row's
                .toggleStyle(.switch)

                Text("Asks your router, by UPnP, NAT-PMP or PCP, to forward TCP and UDP 443 and UDP 4053 to this device, so the extender can be reached from the internet. This opens a port on your router.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Self.inset)
        }
    }
}
#endif
