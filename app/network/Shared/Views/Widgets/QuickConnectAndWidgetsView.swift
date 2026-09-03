//
//  QuickConnectAndWidgetsView.swift
//  URnetwork
//
//  The quick connect control and the Home Screen widgets, drawn with the
//  widgets' own views from a WidgetPreviewData, and the steps to add them,
//  since iOS and macOS have no system request for adding a control or
//  pinning a widget. Shown on the last onboarding page (sample data: nobody
//  has connected yet) and in Account > Widgets (the live snapshots the pinned
//  widgets render), so the two never drift apart.
//

import SwiftUI

struct QuickConnectAndWidgetsView: View {

    @EnvironmentObject var themeManager: ThemeManager

    /// What the widget previews render; the gallery sample unless told otherwise.
    var data: WidgetPreviewData = .sample()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Turn URnetwork on and off from Control Center, and keep an eye on it from your Home Screen.")
                .font(themeManager.currentTheme.bodyFontLarge)

            Spacer().frame(height: 32)

            /**
             * The quick connect control: both states, then how to add it
             */
            HStack(spacing: 28) {
                QuickConnectControlPreview(connected: true)
                QuickConnectControlPreview(connected: false)
                Spacer()
            }

            Spacer().frame(height: 12)

            #if os(macOS)
            Text("Open Control Center, choose Edit Controls, and add URnetwork.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #else
            Text("Open Control Center, tap +, then Add a Control, and pick URnetwork.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #endif

            Spacer().frame(height: 32)

            /**
             * The widgets
             */
            Text("Add Home Screen widgets")
                .font(themeManager.currentTheme.toolbarTitleFont)

            Spacer().frame(height: 12)

            WidgetPreviewCard {
                DashboardWidgetPreview(data: data)
            }

            Spacer().frame(height: 10)

            HStack(alignment: .top, spacing: 10) {
                WidgetPreviewCard {
                    GlobeWidgetPreview(data: data)
                }
                WidgetPreviewCard {
                    ContractsWidgetPreview(data: data)
                }
            }

            Spacer().frame(height: 12)

            #if os(macOS)
            Text("Open the widget gallery from Notification Center, search URnetwork, and drag a widget to the desktop.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #else
            Text("Long-press the Home Screen, tap +, search URnetwork, and add a widget.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #endif
        }
    }
}

/**
 * A Control Center toggle as the system draws it: a rounded square with the
 * connector mark, filled with the app's tint when the tunnel is on.
 */
private struct QuickConnectControlPreview: View {

    let connected: Bool

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(connected ? Color.urPink : Color(red: 0.23, green: 0.23, blue: 0.24))
                Image("ur.symbols.connector.fill")
                    .font(.system(size: 30))
                    .foregroundColor(connected ? .urBlack : Color(red: 0.72, green: 0.72, blue: 0.72))
            }
            .frame(width: 72, height: 72)

            Group {
                if connected {
                    Text("Connected")
                } else {
                    Text("Disconnected")
                }
            }
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(connected ? .urPink : themeManager.currentTheme.textMutedColor)
        }
    }
}

/// A widget-shaped tile: the widget's own container background (so its
/// cards and charts contrast exactly as they do on the Home Screen), edged
/// so the tile reads against the app's matching black.
private struct WidgetPreviewCard<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetTheme.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The dashboard widget at its large size, drawn as DashboardView draws it:
/// location and provider count, the quick connect mark, the balance bar,
/// the client and provider charts, and when the data was written.
private struct DashboardWidgetPreview: View {

    let data: WidgetPreviewData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            BalanceBarView(balance: data.balance)
            charts
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(WidgetTheme.connectorSymbolFill)
                .font(.system(size: 22))
                .foregroundStyle(data.isOn ? WidgetTheme.connected : WidgetTheme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(locationTitle)
                    .font(WidgetTheme.title)
                    .foregroundStyle(WidgetTheme.text)
                    .lineLimit(1)
                subtitle
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // the quick connect button, tinted like the widget's when the tunnel is up
            Image(WidgetTheme.connectorSymbolFill)
                .font(.system(size: 18))
                .foregroundStyle(WidgetTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(data.isOn ? WidgetTheme.tint : WidgetTheme.card, in: Capsule())
        }
    }

    private var locationTitle: LocalizedStringKey {
        if !data.isConfigured {
            return "Not signed in"
        }
        if !data.isOn {
            return "Disconnected"
        }
        guard data.showsTunnelData, let location = data.tunnel.location else {
            return "Connected"
        }
        if location.bestAvailable {
            return "Best available provider"
        }
        return "\(location.name)"
    }

    @ViewBuilder
    private var subtitle: some View {
        if data.showsTunnelData {
            let count = data.tunnel.providers.count
            if data.tunnel.providing {
                Text("\(count) providers · providing")
            } else {
                Text("\(count) providers")
            }
        } else if data.isConfigured {
            Text("URnetwork")
        } else {
            Text("Open URnetwork to set up")
        }
    }

    private var charts: some View {
        let throughput = data.tunnel.throughput
        return VStack(spacing: 8) {
            ThroughputChartView(
                title: "Client",
                color: WidgetTheme.byteSeries,
                points: throughput.buckets.map {
                    ThroughputChartView.Point(
                        start: $0.start,
                        egress: $0.clientEgress, ingress: $0.clientIngress,
                        egressPackets: $0.clientEgressPackets, ingressPackets: $0.clientIngressPackets
                    )
                },
                bucketSeconds: throughput.bucketSeconds,
                now: data.now,
                placeholder: nil
            )
            .frame(height: 66)
            ThroughputChartView(
                title: providerTitle,
                color: WidgetTheme.byteSeries,
                points: throughput.buckets.map {
                    ThroughputChartView.Point(
                        start: $0.start,
                        egress: $0.providerEgress, ingress: $0.providerIngress,
                        egressPackets: $0.providerEgressPackets, ingressPackets: $0.providerIngressPackets
                    )
                },
                bucketSeconds: throughput.bucketSeconds,
                now: data.now,
                placeholder: data.tunnel.providing ? nil : "Provider stats will appear when the provider is enabled."
            )
            .frame(height: 66)
        }
    }

    /// "Provider · Auto": the chart name with the current provide mode.
    private var providerTitle: LocalizedStringKey {
        guard let mode = data.tunnel.provideMode, let label = Self.provideModeLabel(mode) else {
            return "Provider"
        }
        return "Provider · \(label)"
    }

    private static func provideModeLabel(_ mode: String) -> String? {
        switch mode {
        case "auto": return String(localized: "Auto")
        case "always": return String(localized: "Always")
        case "network": return String(localized: "Network")
        case "never": return String(localized: "Never")
        default: return nil
        }
    }

    @ViewBuilder
    private var footer: some View {
        if data.isSample {
            Text("Updated just now")
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textFaint)
        } else if data.tunnel.tunnelActive || data.balance != nil {
            let updatedAt = max(data.tunnel.updatedAt, data.balance?.updatedAt ?? .distantPast)
            Text(updatedLabel(updatedAt))
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textFaint)
        } else {
            Text("Connect once to see your traffic here")
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textFaint)
        }
    }

    /// "Updated 3 min. ago", as the widget's footer reads it.
    private func updatedLabel(_ updatedAt: Date) -> String {
        let elapsed = data.now.timeIntervalSince(updatedAt)
        if elapsed < 60 {
            return String(localized: "Updated just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: updatedAt, relativeTo: data.now)
        return String(format: String(localized: "Updated %@"), relative)
    }
}

/// The providers widget at its small size, as ProviderGlobeView draws it:
/// the globe turned to face the connected providers, the count below.
private struct GlobeWidgetPreview: View {

    let data: WidgetPreviewData

    private var providers: [WidgetProviderSnapshot] {
        data.showsTunnelData ? data.tunnel.providers : []
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeSnapshotView(providers: providers)
            Text(providers.isEmpty ? "No providers" : "\(providers.count) providers")
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(WidgetTheme.background, in: Capsule())
        }
        .frame(height: 150)
    }
}

/// The contracts widget, as ContractsView draws it: one card per peer with
/// its send and receive stacks, flowing until the tile is full.
private struct ContractsWidgetPreview: View {

    let data: WidgetPreviewData

    private var peers: [WidgetContractPeerSnapshot] {
        data.showsTunnelData ? data.tunnel.contractPeers : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Contracts")
                    .font(WidgetTheme.title)
                    .foregroundStyle(WidgetTheme.text)
                Spacer()
                if !peers.isEmpty {
                    let rate = peers.reduce(Int64(0)) { $0 + $1.bitRate }
                    if 0 < rate {
                        Text(formatBitRate(Int(clamping: rate)))
                            .font(WidgetTheme.label)
                            .foregroundStyle(WidgetTheme.textMuted)
                    } else {
                        Text("\(peers.count) peers")
                            .font(WidgetTheme.label)
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                }
            }
            if peers.isEmpty {
                Spacer(minLength: 0)
                Text(emptyMessage)
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ContractFlowLayout(spacing: 6) {
                    ForEach(peers) { peer in
                        ContractPeerCard(peer: peer, compact: true)
                    }
                }
                .clipped()
            }
        }
        .frame(height: 150)
    }

    private var emptyMessage: LocalizedStringKey {
        if !data.isConfigured {
            return "Open URnetwork to set up"
        }
        if !data.isOn {
            return "Connect to see your contracts"
        }
        return "No contracts"
    }
}

#Preview {
    ScrollView {
        QuickConnectAndWidgetsView()
            .padding()
    }
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
}
