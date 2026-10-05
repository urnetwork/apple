//
//  ProviderStatsSection.swift
//  URnetwork
//
//  Provider statistics: local and blocked traffic relayed for remote
//  clients, and how often clients were offered this device. Tap to open the
//  provider contract details.
//

import SwiftUI

struct ProviderStatsSection: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var throughputStore: ThroughputStore
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var providerStatusStore: ProviderStatusStore
    @EnvironmentObject var providePowerStore: ProvidePowerStore

    let navigate: (AccountNavigationPath) -> Void

    @State private var presentTransportSettings = false
    @State private var onScreen = false

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
            powerPauseReason: providePowerStore.powerPauseReason,
            provideNetworkMode: providerIdleNetworkMode(
                allowProvidingCell: deviceManager.allowProvidingCell
            ),
            recentProviderBytes: throughputStore.providerTransportDistribution.byteCount
        )
    }

    /// The line under the provide mode row: the local idle reason merged with
    /// the server's reason (P008). Only while providing is enabled; the plots'
    /// "Providing is disabled" covers Never.
    private var statusLine: ProviderStatusLine? {
        guard deviceManager.provideControlMode != .Never else {
            return nil
        }
        return providerStatusLine(
            idleReason: idleReason,
            serverReason: providerStatusStore.snapshot.reason,
            serverReasonText: providerStatusStore.snapshot.reasonText
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
            if let statusLine {
                Spacer().frame(height: 6)
                ProviderStatusLineRow(line: statusLine, change: { navigate(.settings) })
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

                // how often clients were offered this device, after the
                // other provider plots and under their gate (owner,
                // 2026-10-04). Loading and unavailable keep the chart's height
                if providerStatusStore.snapshot.presentation.area != .hidden {
                    Spacer().frame(height: 12)

                    ProviderDemandSection(snapshot: providerStatusStore.snapshot)
                }
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
        // the provider status polls only while the demand chart shows
        .onAppear {
            onScreen = true
            providerStatusStore.setVisible(providerStatsEnabled)
        }
        .onDisappear {
            onScreen = false
            providerStatusStore.setVisible(false)
        }
        .onChange(of: providerStatsEnabled) { enabled in
            providerStatusStore.setVisible(onScreen && enabled)
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
private struct ProviderStatusLineRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let line: ProviderStatusLine
    let change: () -> Void

    private var text: Text {
        switch line {
        case .idle(let reason):
            return reason.text.map { Text($0) } ?? Text(verbatim: "")
        case .server(let reason):
            return providerStatusReasonText(reason).map { Text($0) } ?? Text(verbatim: "")
        case .serverText(let reasonText):
            // a reason this build does not know: the server's English
            return Text(verbatim: reasonText)
        }
    }

    var body: some View {
        Button(action: change) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                text
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
