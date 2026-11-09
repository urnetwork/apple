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
    // two columns lay the client statistics beside the other sections, for
    // the pane under the canvas of the stacked split connect screen
    var columns: Int = 1

    var body: some View {

        if 2 <= columns {
            HStack(alignment: .top, spacing: 16) {
                clientStatisticsCard

                VStack(spacing: 16) {
                    localStatisticsCard
                    customDnsCard
                    blockerCard
                }
            }
        } else {
            VStack(spacing: 16) {
                clientStatisticsCard
                localStatisticsCard
                customDnsCard
                blockerCard
            }
        }
    }

    /**
     * Client statistics: remote and blocked traffic.
     * Tap to open the client contract details (not on the blocked plot).
     */
    private var clientStatisticsCard: some View {
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
            TransportSettingsEntry(
                distribution: throughputStore.clientTransportDistribution,
                open: { openSheet(.transportSettings) }
            )

            Spacer().frame(height: 12)

            /**
             * The address families of the window's providers: Dualstack,
             * IPv4 and IPv6 columns, each with its connected and connecting
             * counts. Its own view so its grid subscription does not
             * re-render the charts (like DnsRecommendationPill).
             * Tapping it does nothing.
             */
            IpFamilyStatusRow()
                .blocksCardTap()

            Spacer().frame(height: 12)

            /**
             * The extender network: the active extenders' rings, the
             * active-of-usable count, and the gossip network's state
             * (EXTENDER.md K4). Its own view for the same reason as the
             * status row — its once-a-second status subscription must not
             * re-render the charts. Tapping it does nothing.
             */
            ExtenderPanel()
                .blocksCardTap()

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
            /**
             * Tapping the blocked plot does nothing: it is not part of
             * the client contracts.
             */
            .blocksCardTap()

        }
    }

    /**
     * Local statistics: traffic routed to the local network.
     * Tap to open the split rules.
     */
    private var localStatisticsCard: some View {
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
    }

    /**
     * Custom dns summary. Tap to open the dns settings, once the
     * store has them: the editor never starts from the blank form
     * (SettingsEditorSeed).
     */
    private var customDnsCard: some View {
        statsCard(action: {
            if dnsSettingsStore.settings != nil {
                openSheet(.dnsSettings)
            }
        }) {

            cardHeader("Custom DNS")

            // a nudge when the applied dns settings differ from the recommended
            // ones (regional recommendation, or the safe defaults), a dropped
            // preset's notice, and a failing preset's status
            DnsRecommendationPill()

            if let settings = dnsSettingsStore.settings {
                VStack(spacing: 8) {
                    // what the settings select: "DNS: AdGuard DNS · Ad blocking"
                    DnsSelectionLine()
                        .frame(minHeight: dnsStatusRowHeight)
                    dnsStatusRow("DNS over HTTPS", enabled: settings.dohEnabled)
                    dnsStatusRow("Unencrypted DNS", enabled: settings.unencryptedDnsEnabled)
                    dnsStatusRow("Local DNS", enabled: settings.localDnsEnabled)
                    dnsStatusRow("Fast DNS on connect", enabled: settings.fastDnsOnConnectEnabled)
                }
            } else {
                // the settings arrive once the device attaches (the store
                // publishes nil until then); reserve the selection line and
                // the four rows at their final height so the drawer's content
                // does not grow when they land (mmm/DESIGNSTYLE.md
                // "Placeholders, not pop-in")
                VStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { _ in
                        dnsStatusRowSkeleton()
                    }
                }
                .skeletonGroup("Loading...")
            }

        }
    }

    /**
     * URnetwork's own ad and tracker blocker toggle. The device applies it
     * immediately and persists it to local settings. Labeled as URnetwork's,
     * since "Block ads and trackers" now heads the dns providers that block
     * them (connect ADBLOCK3RD F1 item 6): both can be on.
     */
    private var blockerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            UrSwitchToggle(isOn: $deviceManager.blockerEnabled) {
                Text("URnetwork ad blocker")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            Text("URnetwork's own blocker. It works with any DNS choice and checks each name first.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
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

    /// The same box as `dnsStatusRow`: the 6pt dot, the title's line, the
    /// trailing state word. The row's height is the body font's line height,
    /// which the skeleton takes from a hidden text of the same font so it
    /// tracks Dynamic Type exactly.
    private func dnsStatusRowSkeleton() -> some View {
        HStack(spacing: 8) {
            Skeleton(width: 6, height: 6, cornerRadius: 3)
            Skeleton(width: 132, height: 12)
            Spacer()
            Skeleton(width: 24, height: 10)
        }
        .frame(minHeight: dnsStatusRowHeight)
    }

    /// The height of a rendered status row: the taller of its two fonts.
    private var dnsStatusRowHeight: CGFloat {
        #if os(iOS)
        return UIFont.preferredFont(forTextStyle: .body).lineHeight
        #else
        return NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height
        #endif
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
        .frame(minHeight: dnsStatusRowHeight)
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

private extension View {
    /// Keeps a tap on an informational panel inside a stats card from opening
    /// the card's details. The empty child tap wins over the card's tap, like
    /// the transport bar's, and the content shape extends it to the gaps
    /// between the panel's text so no part of the panel falls through.
    func blocksCardTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture {}
    }
}

/**
 * Pills shown atop the Custom DNS card, as the sdk describes the applied dns
 * settings (`DescribeDnsResolverSettings`, `DescribeDnsResolverStatus`):
 * - the notice of a stored preset this release no longer offers, which
 *   URnetwork's dns replaces (connect ADBLOCK3RD A7);
 * - the status of a selected preset that is failing (C8);
 * - the nudge when the settings differ from the recommended ones: the
 *   connected country's regional recommendation (with the country color)
 *   when it has one, otherwise the safe defaults. Never while a preset is
 *   selected, an explicit choice whose problems show as its status (F2).
 * Nothing is shown when none applies. Extracted like SplitRuleCountLabel so
 * its connectViewModel / dnsSettingsStore subscriptions don't re-render the
 * charts.
 */
private struct DnsRecommendationPill: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var connectViewModel: ConnectViewModel

    /// the pills' messages, each with the country code whose color dots it
    /// (the regional recommendation's), in the order they show
    private var pills: [(message: Text, countryCode: String?)] {
        let exitCountryCode = connectViewModel.selectedProvider?.countryCode
        guard let summary = dnsSettingsStore.selectionSummary(exitCountryCode: exitCountryCode) else {
            return []
        }
        var pills: [(message: Text, countryCode: String?)] = []
        if summary.dropped {
            if summary.droppedNameKey.isEmpty {
                // an id this release never knew has no name: the generic copy
                pills.append((message: Text("This preset isn't available. Choose another one."), countryCode: nil))
            } else {
                // named as it showed
                let droppedName = dnsPresetName(summary.droppedNameKey, provider: summary.droppedNameProvider)
                pills.append((message: Text("\(droppedName) is no longer available. You're using URnetwork DNS, so lookups aren't filtered."), countryCode: nil))
            }
        }
        if let status = dnsSettingsStore.statusSummary, status.showUseDefault,
           let line = dnsStatusText(status.statusKey, provider: dnsPresetName(status.nameKey, provider: status.nameProvider)) {
            pills.append((message: Text(line), countryCode: nil))
        }
        let countryCode = summary.pillCountryCode
        let country = connectViewModel.selectedProvider?.country ?? countryCode.uppercased()
        if let message = dnsPillText(summary.pillKey, country: country) {
            pills.append((message: Text(message), countryCode: countryCode.isEmpty ? nil : countryCode))
        }
        return pills
    }

    var body: some View {
        let pills = self.pills
        if !pills.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pills.indices, id: \.self) { i in
                    pill(pills[i].message, countryCode: pills[i].countryCode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
    }

    private func pill(_ message: Text, countryCode: String?) -> some View {
        HStack(spacing: 6) {
            if let countryCode {
                Circle()
                    .fill(Color(hex: SdkGetColorHex(countryCode)))
                    .frame(width: 8, height: 8)
            }
            message
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.urCoral.opacity(0.15)))
    }
}

/**
 * What the applied dns settings select, as the summary row reads
 * (`DescribeDnsResolverSettings`, connect ADBLOCK3RD F1): "DNS: URnetwork",
 * "DNS: AdGuard Ad Blocking", "DNS: NextDNS Personal", "DNS: Custom", a
 * preset by its name. Its own view for the same reason as
 * DnsRecommendationPill.
 */
private struct DnsSelectionLine: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var connectViewModel: ConnectViewModel

    var body: some View {
        let summary = dnsSettingsStore.selectionSummary(exitCountryCode: connectViewModel.selectedProvider?.countryCode)
        HStack(spacing: 8) {
            if let summary, let text = dnsSummaryText(summary.summaryKey, provider: dnsPresetName(summary.nameKey, provider: summary.nameProvider)) {
                Text(text)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

/**
 * The client transport bar, which opens the transport settings editor once
 * the store has the device's policy: the editor never starts from the
 * defaults (SettingsEditorSeed). Its own view so its transportSettingsStore
 * subscription does not re-render the charts.
 */
private struct TransportSettingsEntry: View {
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore

    let distribution: TransportDistribution
    let open: () -> Void

    var body: some View {
        TransportDistributionBar(
            distribution: distribution,
            action: {
                if transportSettingsStore.clientSettings != nil {
                    open()
                }
            }
        )
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
        // never inflect in the interpolation, it is untranslatable. The macOS
        // excluded apps are split rules too (app rules)
        Text("\(blockActionsStore.splitRules.count + blockActionsStore.appRules.count) split rules")
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
    // opens the location picker, for the dns sheet's "Change location"
    var openLocations: () -> Void = {}
    // the dns sheet asked for the location picker: it opens once the sheet
    // is dismissed, since a presentation made while another one dismisses
    // can be dropped
    @State var opensLocationsOnDismiss = false

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var connectViewModel: ConnectViewModel
    #if os(macOS)
    // the split rules sheet's Apps section
    @EnvironmentObject var splitTunnelProxyController: SplitTunnelProxyController
    #endif

    func body(content: Content) -> some View {
        content
            .sheetOffTheFold(item: $presentedStatsSheet, onDismiss: {
                if opensLocationsOnDismiss {
                    opensLocationsOnDismiss = false
                    openLocations()
                }
            }) { sheet in
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
                // Provider Locations reads the current location and connects
                // for "Stay on this exit"
                .environmentObject(connectViewModel)
                #if os(macOS)
                .environmentObject(splitTunnelProxyController)
                #endif
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
            connectedCountryName: connectViewModel.selectedProvider?.country,
            changeLocation: {
                opensLocationsOnDismiss = true
                presentedStatsSheet = nil
            }
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
