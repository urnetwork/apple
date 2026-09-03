//
//  ProviderStatsSection.swift
//  URnetwork
//
//  Provider statistics: local and blocked traffic relayed for remote
//  clients. Tap to open the provider contract details.
//

import SwiftUI

struct ProviderStatsSection: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var throughputStore: ThroughputStore
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore
    @EnvironmentObject var deviceManager: DeviceManager

    let navigate: (AccountNavigationPath) -> Void

    @State private var presentTransportSettings = false

    /// Whether the provider plots show: the provide mode the user picked (the
    /// same value the provide-mode row displays) must not be Never, and the
    /// device must be publishing provider stats. With the mode on Never the
    /// section shows the providing-disabled message instead, whatever the
    /// device's live provide state says.
    private var providerStatsEnabled: Bool {
        deviceManager.provideControlMode != .Never && throughputStore.hasProviderStats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                UrLabel(text: "Provider statistics")
                Spacer()
                if providerStatsEnabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                }
            }

            Spacer().frame(height: 8)

            // the current provide mode, rendered like the settings picker;
            // tapping the row opens settings to change it
            ProvideModeRow(action: { navigate(.settings) })

            Spacer().frame(height: 8)

            if providerStatsEnabled {
                TransferChart(
                    points: throughputStore.providerPoints,
                    route: .local,
                    title: "Local",
                    window: throughputStore.windowDuration
                )

                Spacer().frame(height: 12)

                /**
                 * The relayed traffic of the window by the transport this
                 * device used to carry it, under the provider plot. Tap to
                 * open the provider transport settings.
                 */
                TransportDistributionBar(
                    distribution: throughputStore.providerTransportDistribution,
                    action: { presentTransportSettings = true }
                )

                Spacer().frame(height: 12)

                TransferChart(
                    points: throughputStore.providerPoints,
                    route: .block,
                    title: "Blocked",
                    height: 64,  // secondary series — half height
                    window: throughputStore.windowDuration,
                    byteColor: .urCoral,
                    packetColor: .urMutedCoral
                )
            } else {
                Text("Providing is disabled")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
                    .padding(.bottom, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if providerStatsEnabled {
                navigate(.providerContracts)
            }
        }
        .sheet(isPresented: $presentTransportSettings) {
            let transportView = TransportSettingsView(
                kind: .provider,
                settings: transportSettingsStore.providerSettings
            )
            Group {
                #if os(macOS)
                transportView.frame(minWidth: 480, minHeight: 540)
                #else
                transportView
                #endif
            }
            .environmentObject(themeManager)
            .environmentObject(transportSettingsStore)
        }
    }
}
