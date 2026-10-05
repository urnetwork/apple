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
        providerStatisticsVisible(
            provideControlMode: deviceManager.provideControlMode,
            hasProviderStats: throughputStore.hasProviderStats
        )
    }

    /// Why the enabled provider is idle (P008), from the live provide state
    /// and the bytes relayed in the throughput window.
    private var idleReason: ProviderIdleReason {
        providerIdleReason(
            controlMode: deviceManager.provideControlMode,
            liveProvideMode: deviceManager.currentProvideMode,
            providePaused: deviceManager.providePaused,
            provideNetworkMode: providerIdleNetworkMode(
                allowProvidingCell: deviceManager.allowProvidingCell
            ),
            recentProviderBytes: throughputStore.providerTransportDistribution.byteCount
        )
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

            // why the enabled provider is idle, under the mode it explains.
            // Change opens the same settings as the row
            if let text = idleReason.text {
                Spacer().frame(height: 6)
                ProviderIdleReasonRow(text: text, change: { navigate(.settings) })
            }

            #if os(macOS)
            // the Extender row, read-only, under the provide mode row and
            // opening the same settings (EXTENDER.md N7). It shows whether or
            // not the statistics do, since its text matters most while the
            // role is off or not providing
            if deviceManager.extenderProvideStatus.supported {
                Spacer().frame(height: 8)
                ExtenderProvideRow(kind: .readOnly(action: { navigate(.settings) }))
            }
            #endif

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

/// One muted line saying why the provider is idle, with a Change action. A
/// button, so a tap opens settings rather than the section's provider
/// contracts.
private struct ProviderIdleReasonRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringResource
    let change: () -> Void

    var body: some View {
        Button(action: change) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Change")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .underline()
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Whether the provider statistics show (EXTENDER.md O8): the provide mode the
/// user picked is not never and the device reports provider stats. The one gate
/// of the reliability block, the provider plots and the extender statistics.
func providerStatisticsVisible(
    provideControlMode: ProvideControlMode,
    hasProviderStats: Bool
) -> Bool {
    provideControlMode != .Never && hasProviderStats
}
