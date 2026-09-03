//
//  DashboardView.swift
//  URnetworkWidgets
//
//  Layout of the dashboard widget. Rendered once per timeline entry; the only
//  live elements are the relative-time texts, which WidgetKit advances on
//  screen without a reload.
//

import AppIntents
import SwiftUI
import WidgetKit

struct DashboardView: View {

    @Environment(\.widgetFamily) private var family

    let entry: SnapshotEntry

    var body: some View {
        Group {
            if family == .systemLarge {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    BalanceBarView(balance: entry.balance)
                    charts
                    Spacer(minLength: 0)
                    footer
                }
            } else {
                // the short widget is exactly the large one's top section:
                // location, provider count, quick connect, balance bar
                VStack(alignment: .leading, spacing: 10) {
                    header
                    BalanceBarView(balance: entry.balance)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        // a tap anywhere else opens the app on the connect tab
        .widgetURL(WidgetDestination.connect.url)
    }

    // MARK: Header: location + quick connect

    private var header: some View {
        HStack(spacing: 10) {
            // the location's country color, as the in-app location list shows it
            LocationColorDot(location: entry.showsTunnelData ? entry.tunnel.location : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(locationTitle)
                    .font(WidgetTheme.title)
                    .foregroundStyle(WidgetTheme.text)
                    .lineLimit(1)
                    .widgetAccentable()
                subtitle
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            QuickConnectButton(entry: entry)
        }
    }

    private var locationTitle: LocalizedStringKey {
        if !entry.isConfigured {
            return "Not signed in"
        }
        if !entry.isOn {
            return "Disconnected"
        }
        guard entry.showsTunnelData, let location = entry.tunnel.location else {
            return "Connected"
        }
        if location.bestAvailable {
            return "Best available provider"
        }
        return "\(location.name)"
    }

    @ViewBuilder
    private var subtitle: some View {
        if entry.showsTunnelData {
            let count = entry.tunnel.providers.count
            if entry.tunnel.providing {
                Text("\(count) providers · providing")
            } else {
                Text("\(count) providers")
            }
        } else if entry.isConfigured {
            Text("URnetwork")
        } else {
            Text("Open URnetwork to set up")
        }
    }

    // MARK: Charts (large)

    private var charts: some View {
        let throughput = entry.tunnel.throughput
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
                now: entry.date,
                placeholder: nil
            )
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
                now: entry.date,
                placeholder: entry.tunnel.providing ? nil : "Provider stats will appear when the provider is enabled."
            )
        }
    }

    /// "Provider · Auto": the chart name with the current provide mode.
    private var providerTitle: LocalizedStringKey {
        guard let mode = entry.tunnel.provideMode, let label = Self.provideModeLabel(mode) else {
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

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if entry.isPreview {
            Text("Updated just now")
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textFaint)
        } else if entry.tunnel.tunnelActive || entry.balance != nil {
            let updatedAt = max(entry.tunnel.updatedAt, entry.balance?.updatedAt ?? .distantPast)
            Text(updatedLabel(updatedAt))
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textFaint)
        } else {
            Text("Connect once to see your traffic here")
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textFaint)
        }
    }
}

extension DashboardView {

    /// "Updated 3 min. ago", formatted for the timeline entry's date (entries
    /// are five minutes apart, so this advances at that cadence). Not a
    /// relative-time Text: that reserves the width of its widest possible
    /// value inside the sentence.
    private func updatedLabel(_ updatedAt: Date) -> String {
        let elapsed = entry.date.timeIntervalSince(updatedAt)
        if elapsed < 60 {
            return String(localized: "Updated just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: updatedAt, relativeTo: entry.date)
        return String(format: String(localized: "Updated %@"), relative)
    }
}

/// The in-widget quick connect: the same intent as the Control Center
/// toggle, drawn as a bordered button carrying the connector mark. WidgetKit
/// flips a toggle optimistically before the timeline is re-rendered, and the
/// only toggle style it can archive is the button one (a switch renders as
/// the "unsupported view" marker), so the button's tint alone carries the
/// on/off state: the mark inside it is constant, while the header's mark and
/// title show the last rendered state until the reload. A device with no
/// tunnel configuration gets an "open the app" button instead, since only
/// the app can create the configuration.
struct QuickConnectButton: View {

    let entry: SnapshotEntry

    var body: some View {
        if entry.isConfigured {
            Toggle(
                isOn: entry.isOn,
                intent: ToggleTunnelIntent(value: !entry.isOn, source: TunnelIntentStore.sourceWidget)
            ) {
                Label {
                    Text(entry.isOn ? "Disconnect" : "Connect")
                } icon: {
                    Image(WidgetTheme.connectorSymbolFill)
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 18))
                // white mark in both states; the capsule behind it is gray
                // when off and the tint (pink) when on
                .foregroundStyle(WidgetTheme.text)
            }
            .toggleStyle(.button)
            .tint(WidgetTheme.tint)
            .accessibilityLabel(entry.isOn ? Text("Disconnect") : Text("Connect"))
        } else {
            Button(intent: OpenURnetworkIntent()) {
                Text("Open")
                    .font(WidgetTheme.caption)
            }
            .buttonStyle(.bordered)
            .tint(WidgetTheme.tint)
        }
    }
}
