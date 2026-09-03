//
//  ContractsWidget.swift
//  URnetworkWidgets
//
//  The top client contracts as a flowing grid: one compact card per peer,
//  each with its send stack and its receive stack (contracts are never
//  paired: a peer's send and receive contracts are many-to-many, so each
//  is its own circle). Cards are laid out left to right and wrap until the
//  widget is full; whatever does not fit is left out, most relevant peers
//  first (moving bytes now, then most recently active, then most bytes).
//

import SwiftUI
import WidgetKit

struct ContractsWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKinds.contracts,
            provider: SnapshotTimelineProvider()
        ) { entry in
            ContractsView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetTheme.background
                }
        }
        .configurationDisplayName("Contracts")
        .description("Your top client contracts, flowing as they come and go.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ContractsView: View {

    @Environment(\.widgetFamily) private var family

    let entry: SnapshotEntry

    private var peers: [WidgetContractPeerSnapshot] {
        entry.showsTunnelData ? entry.tunnel.contractPeers : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if peers.isEmpty {
                Spacer(minLength: 0)
                Text(emptyMessage)
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textFaint)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ContractFlowLayout(spacing: 6) {
                    ForEach(peers) { peer in
                        ContractPeerCard(peer: peer, compact: family == .systemSmall)
                    }
                }
                .clipped()
            }
        }
        // a tap opens the app on the client contract details
        .widgetURL(WidgetDestination.contracts.url)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Contracts")
                .font(WidgetTheme.title)
                .foregroundStyle(WidgetTheme.text)
                .widgetAccentable()
            Spacer()
            if !peers.isEmpty {
                let rate = peers.reduce(Int64(0)) { $0 + $1.bitRate }
                if 0 < rate {
                    Text(formatBitRate(Int(clamping: rate)))
                        .font(WidgetTheme.label)
                        .foregroundStyle(WidgetTheme.textMuted)
                } else if family != .systemSmall {
                    Text("\(peers.count) peers")
                        .font(WidgetTheme.label)
                        .foregroundStyle(WidgetTheme.textMuted)
                }
            }
        }
    }

    private var emptyMessage: LocalizedStringKey {
        if !entry.isConfigured {
            return "Open URnetwork to set up"
        }
        if !entry.isOn {
            return "Connect to see your contracts"
        }
        return "No contracts"
    }
}
