//
//  ConnectStatsSections.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import SwiftUI
import URnetworkSdk

/**
 * The detail views reachable from the connect drawer statistics sections
 */
enum ConnectStatsSheet: String, Identifiable {
    case clientContracts
    case splitRules
    case dnsSettings
    case providerLocations
    case transportSettings

    var id: String { rawValue }
}

/**
 * The statistics sections in the connect drawer: client statistics,
 * local statistics, and custom dns
 */
struct ConnectStatsSections: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var throughputStore: ThroughputStore
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var deviceManager: DeviceManager

    let openSheet: (ConnectStatsSheet) -> Void

    var body: some View {

        VStack(spacing: 16) {

            /**
             * Client statistics: remote and blocked traffic.
             * Tap to open the client contract details.
             */
            statsCard(action: { openSheet(.clientContracts) }) {

                cardHeader("Client statistics")

                TransferChart(
                    points: throughputStore.clientPoints,
                    route: .remote,
                    title: "Remote",
                    window: throughputStore.windowDuration
                )

                Spacer().frame(height: 12)

                /**
                 * The remote traffic of the window by transport, full width
                 * under the remote plot. Tap to open the transport settings.
                 * The child tap wins over the card's tap.
                 */
                TransportDistributionBar(
                    distribution: throughputStore.clientTransportDistribution,
                    action: { openSheet(.transportSettings) }
                )

                Spacer().frame(height: 12)

                TransferChart(
                    points: throughputStore.clientPoints,
                    route: .block,
                    title: "Blocked",
                    height: 64,  // secondary series — half height
                    window: throughputStore.windowDuration,
                    byteColor: .urCoral,
                    packetColor: .urMutedCoral
                )

            }

            /**
             * Local statistics: traffic routed to the local network.
             * Tap to open the split rules.
             */
            statsCard(action: { openSheet(.splitRules) }) {

                cardHeader("Local statistics")

                TransferChart(
                    points: throughputStore.clientPoints,
                    route: .local,
                    title: "Local",
                    height: 64,  // secondary series — half height
                    window: throughputStore.windowDuration
                )

                Spacer().frame(height: 12)

                SplitRuleCountLabel()

            }

            /**
             * Custom dns summary. Tap to open the dns settings.
             */
            statsCard(action: { openSheet(.dnsSettings) }) {

                cardHeader("Custom DNS")

                // a nudge when the applied dns settings differ from the recommended
                // ones (regional recommendation, or the safe defaults)
                DnsRecommendationPill()

                if let settings = dnsSettingsStore.settings {
                    VStack(spacing: 8) {
                        dnsStatusRow("DNS over HTTPS", enabled: settings.dohEnabled)
                        dnsStatusRow("Unencrypted DNS", enabled: settings.unencryptedDnsEnabled)
                        dnsStatusRow("Local DNS", enabled: settings.localDnsEnabled)
                        dnsStatusRow("Local DNS fallback", enabled: settings.localDnsFallbackEnabled)
                    }
                } else {
                    Text("DNS settings unavailable")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                }

            }

            /**
             * Ad and tracker blocker toggle. The device applies it immediately
             * and persists it to local settings.
             */
            VStack(alignment: .leading, spacing: 0) {
                UrSwitchToggle(isOn: $deviceManager.blockerEnabled) {
                    Text("Block ads and trackers")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)

        }
    }

    private func cardHeader(_ title: LocalizedStringKey) -> some View {
        HStack(alignment: .center) {
            UrLabel(text: title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.textFaintColor)
        }
        .padding(.bottom, 8)
    }

    private func dnsStatusRow(_ title: LocalizedStringKey, enabled: Bool) -> some View {
        HStack(spacing: 8) {

            Circle()
                .fill(enabled ? Color.urGreen : themeManager.currentTheme.textFaintColor.opacity(0.4))
                .frame(width: 6, height: 6)

            Text(title)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            Spacer()

            Text(enabled ? "On" : "Off")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(
                    enabled ? .urGreen : themeManager.currentTheme.textMutedColor
                )
        }
    }

    private func statsCard<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }
}

/**
 * A pill shown atop the Custom DNS card when the applied dns settings differ from
 * the recommended ones: the connected country's regional recommendation (with the
 * country color) when it has one, otherwise the safe defaults. Nothing is shown
 * when the applied settings already match. Extracted like SplitRuleCountLabel so
 * its connectViewModel / dnsSettingsStore subscriptions don't re-render the charts.
 */
private struct DnsRecommendationPill: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var connectViewModel: ConnectViewModel

    /// the pill message and, for a regional recommendation, the country code whose
    /// color dots the pill; nil when the applied settings already match
    private var recommendation: (message: LocalizedStringKey, countryCode: String?)? {
        guard let current = dnsSettingsStore.settings else {
            return nil
        }
        // a connected country with a known-better regional recommendation takes precedence
        if let code = connectViewModel.selectedProvider?.countryCode,
           let sdkRecommended = SdkGetRecommendedDnsResolverSettings(code) {
            if current != DnsSettings(sdkRecommended) {
                let name = connectViewModel.selectedProvider?.country ?? code.uppercased()
                let message: LocalizedStringKey = "There are unapplied recommended settings for \(name)"
                return (message, code)
            }
            // already on the regional recommendation
            return nil
        }
        // otherwise nudge toward the safe defaults when they aren't applied
        if let sdkDefault = SdkGetDefaultDnsResolverSettings(), current != DnsSettings(sdkDefault) {
            let message: LocalizedStringKey = "The default safe settings are not applied"
            return (message, nil)
        }
        return nil
    }

    var body: some View {
        if let recommendation {
            HStack(spacing: 6) {
                if let code = recommendation.countryCode {
                    Circle()
                        .fill(Color(hex: SdkGetColorHex(code)))
                        .frame(width: 8, height: 8)
                }
                Text(recommendation.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.urCoral.opacity(0.15)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
    }
}

/**
 * The split-rule count. Extracted so it — not the chart-bearing
 * ConnectStatsSections — carries the blockActionsStore subscription, keeping the
 * traffic-frequency block-action/stats publishes from re-rendering the three
 * transfer charts on every routing decision.
 */
private struct SplitRuleCountLabel: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore

    var body: some View {
        // real plural rules live in Localizable.xcstrings ("%lld split rules");
        // never inflect in the interpolation, it is untranslatable
        Text("\(blockActionsStore.splitRules.count) split rules")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
    }
}

/**
 * Presents the client-contracts / split-rules / DNS detail sheets. Implemented
 * as a modifier that holds the blockActionsStore / dnsSettingsStore
 * subscriptions so their high-frequency publishes invalidate only this small
 * presenter, not the always-mounted connect screen it is attached to.
 */
struct ConnectStatsSheets: ViewModifier {

    @Binding var presentedStatsSheet: ConnectStatsSheet?

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var connectViewModel: ConnectViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedStatsSheet) { sheet in
                Group {
                    switch sheet {
                    case .clientContracts:
                        StatsSheetContainer(title: "Client contracts") {
                            ContractDetailsView(mode: .client)
                        }
                    case .splitRules:
                        StatsSheetContainer(title: "Split rules") {
                            SplitRulesView()
                        }
                    case .providerLocations:
                        StatsSheetContainer(title: "Provider Locations") {
                            ProviderLocationsView()
                        }
                    case .dnsSettings:
                        dnsSettingsSheet
                    case .transportSettings:
                        transportSettingsSheet
                    }
                }
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(blockActionsStore)
                .environmentObject(dnsSettingsStore)
                .environmentObject(transportSettingsStore)
                .environmentObject(snackbarManager)
            }
    }

    @ViewBuilder
    private var transportSettingsSheet: some View {
        let transportView = TransportSettingsView(
            kind: .client,
            settings: transportSettingsStore.clientSettings
        )
        #if os(macOS)
        transportView.frame(minWidth: 480, minHeight: 540)
        #else
        transportView
        #endif
    }

    @ViewBuilder
    private var dnsSettingsSheet: some View {
        let dnsView = DnsSettingsView(
            settings: dnsSettingsStore.settings,
            connectedCountryCode: connectViewModel.selectedProvider?.countryCode,
            connectedCountryName: connectViewModel.selectedProvider?.country
        )
        #if os(macOS)
        dnsView.frame(minWidth: 480, minHeight: 540)
        #else
        dnsView
        #endif
    }
}

/**
 * A shared sheet frame with a title and close button
 */
struct StatsSheetContainer<Content: View>: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Text(title)
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding()

            content

        }
        .background(themeManager.currentTheme.backgroundColor)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #endif
    }
}
