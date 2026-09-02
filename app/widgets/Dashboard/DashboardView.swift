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

    // MARK: Header: location + quick connect

    private var header: some View {
        HStack(spacing: 10) {
            // the solid connector: white when off, the app's connected green
            // when the tunnel is up (pink is reserved for the quick connect
            // button and the control)
            Image(WidgetTheme.connectorSymbolFill)
                .font(.system(size: 22))
                .foregroundStyle(entry.isOn ? WidgetTheme.connected : WidgetTheme.text)
                .widgetAccentable()
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
                color: WidgetTheme.clientSeries,
                points: throughput.buckets.map {
                    ThroughputChartView.Point(start: $0.start, egress: $0.clientEgress, ingress: $0.clientIngress)
                },
                bucketSeconds: throughput.bucketSeconds,
                now: entry.date,
                placeholder: nil
            )
            ThroughputChartView(
                title: "Provider",
                color: WidgetTheme.providerSeries,
                points: throughput.buckets.map {
                    ThroughputChartView.Point(start: $0.start, egress: $0.providerEgress, ingress: $0.providerIngress)
                },
                bucketSeconds: throughput.bucketSeconds,
                now: entry.date,
                placeholder: entry.tunnel.providing ? nil : "Not providing"
            )
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

/// The three-segment transfer balance bar, as the app's UsageBar draws it:
/// used, pending, available out of the daily start balance. Segments are
/// clamped to a minimum width so a small one still shows.
struct BalanceBarView: View {

    let balance: WidgetBalanceSnapshot?

    private static let minimumFraction = 0.015
    private static let barHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Balance")
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                Spacer()
                Text(summary)
                    .font(WidgetTheme.label)
                    .foregroundStyle(WidgetTheme.text)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(segments(width: geometry.size.width), id: \.id) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: segment.width)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: Self.barHeight)
        }
    }

    private var summary: String {
        guard let balance else {
            return "—"
        }
        let available = formatBalanceBytes(Int(clamping: balance.balanceByteCount))
        let start = formatBalanceBytes(Int(clamping: balance.startBalanceByteCount))
        return "\(available) / \(start)"
    }

    private struct Segment {
        let id: Int
        let color: Color
        let width: CGFloat
    }

    private func segments(width: CGFloat) -> [Segment] {
        guard let balance, 0 < balance.startBalanceByteCount else {
            return [Segment(id: 0, color: WidgetTheme.balanceAvailable.opacity(0.5), width: width)]
        }
        let total = Double(balance.startBalanceByteCount)
        let raw: [(Color, Double)] = [
            (WidgetTheme.balanceUsed, Double(balance.usedByteCount) / total),
            (WidgetTheme.balancePending, Double(balance.openTransferByteCount) / total),
            (WidgetTheme.balanceAvailable, Double(balance.balanceByteCount) / total),
        ]
        // clamp non-zero segments up to the minimum, then renormalize
        var fractions = raw.map { $0.1 <= 0 ? 0 : max($0.1, Self.minimumFraction) }
        let sum = fractions.reduce(0, +)
        if 0 < sum {
            fractions = fractions.map { $0 / sum }
        }
        let gaps = CGFloat(max(0, fractions.filter { 0 < $0 }.count - 1)) * 2
        let usable = max(0, width - gaps)
        return raw.enumerated().compactMap { index, item in
            let fraction = fractions[index]
            guard 0 < fraction else { return nil }
            return Segment(id: index, color: item.0, width: usable * CGFloat(fraction))
        }
    }
}
