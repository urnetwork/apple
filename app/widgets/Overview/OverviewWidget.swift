//
//  OverviewWidget.swift
//  URnetworkWidgets
//
//  The overview: the dashboard, the provider globe and the contracts in one
//  widget, in the largest family each device offers (apple/DUO.md, "Samsung
//  cover screen (item 16)", option A). The header is the dashboard's: the
//  location and its status line, or the slow internet pill in its place, and
//  the quick connect toggle. The provider globe fills the bottom left,
//  bleeding off the widget's edges; three tiles down the right carry the
//  balance, today's traffic and the open contracts. Disconnected, the globe
//  dims and traffic and contracts read "—".
//
//  One timeline with the other widgets (SnapshotTimelineProvider), and
//  reloaded whenever one of them is (WidgetRefresh). What shows and where is
//  decided in WidgetOverview, shared with the app's tests; this draws it.
//

import SwiftUI
import WidgetKit
#if os(iOS)
import UIKit
#endif

struct OverviewWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKinds.overview,
            provider: SnapshotTimelineProvider()
        ) { entry in
            OverviewView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetTheme.background
                }
        }
        .configurationDisplayName("Overview")
        .description("Connection, providers on the globe, balance, today's traffic and contracts in one widget, with quick connect.")
        .supportedFamilies(Self.families)
        // the globe bleeds off the edges, so the header and the tiles keep
        // the system's margins themselves
        .contentMarginsDisabled()
    }

    /// The largest family each device offers: extra large on iPad and the
    /// Mac, large on iPhone. The iOS 27.1 SDK says nothing of the iPhone Duo:
    /// WidgetKit keeps systemExtraLarge at iOS 15 with no device condition,
    /// and its one new family is systemExtraLargePortrait. So the Duo, a
    /// phone, gets large like any iPhone.
    private static var families: [WidgetFamily] {
        #if os(macOS)
        return [.systemExtraLarge]
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? [.systemExtraLarge] : [.systemLarge]
        #endif
    }
}

struct OverviewView: View {

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins

    let entry: SnapshotEntry

    var body: some View {
        OverviewContent(entry: entry, wide: family == .systemExtraLarge, margins: margins)
            // a tap anywhere but the toggle opens the app on the connect
            // tab, as the dashboard's does
            .widgetURL(WidgetDestination.connect.url)
    }
}

/// The overview laid out for its family: `wide` at extra large, the header
/// and the tiles inside `margins`, the globe past them.
struct OverviewContent: View {

    let entry: SnapshotEntry
    let wide: Bool
    let margins: EdgeInsets

    /// Disconnected, the globe shows at this opacity.
    private static let dimmedOpacity = 0.45
    private static let headerSpacing: CGFloat = 8
    private static let tileSpacing: CGFloat = 6
    /// Wide, a tile's name and figure take this share of it, the same in
    /// every tile so the pictures line up.
    private static let wideLabelShare: CGFloat = 0.3

    var body: some View {
        let overview = WidgetOverview(
            tunnel: entry.tunnel,
            balance: entry.balance,
            showsTunnelData: entry.showsTunnelData,
            now: entry.date
        )
        GeometryReader { geometry in
            let layout = WidgetOverviewLayout(
                width: geometry.size.width,
                height: geometry.size.height,
                wide: wide
            )
            ZStack(alignment: .topLeading) {
                GlobeSnapshotView(providers: overview.providers, dotColor: WidgetTheme.byteSeries)
                    .frame(width: layout.globeDiameter, height: layout.globeDiameter)
                    .opacity(overview.dimmed ? Self.dimmedOpacity : 1)
                    .offset(x: layout.globeLeft, y: layout.globeTop)
                    // decorative: the header says the provider count
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Self.headerSpacing) {
                    DashboardHeader(entry: entry, leadsWithConnected: true)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        tiles(overview, layout: layout)
                            .frame(width: layout.tileWidth)
                    }
                }
                .padding(margins)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    /// Large: the balance and the contracts take what they need and the
    /// traffic the rest. Extra large: all three flex, so they share the
    /// height in equal rows, each tile wide.
    private func tiles(_ overview: WidgetOverview, layout: WidgetOverviewLayout) -> some View {
        let wideTiles = layout.wideTiles
        let labelWidth = Self.wideLabelShare * layout.tileWidth
        return VStack(spacing: Self.tileSpacing) {
            OverviewTile(name: "Balance", figure: overview.balance, wide: wideTiles, labelWidth: labelWidth) {
                BalanceBar(balance: entry.balance, height: 6)
            }
            .fixedSize(horizontal: false, vertical: !wideTiles)
            OverviewTile(name: "Traffic today", figure: overview.traffic, wide: wideTiles, labelWidth: labelWidth) {
                if let hours = overview.trafficHours {
                    TrafficSparkline(hours: hours)
                }
            }
            OverviewTile(name: "Contracts", figure: overview.contracts, wide: wideTiles, labelWidth: labelWidth) {
                ContractStacks(overview: overview, compact: !wideTiles)
            }
            .fixedSize(horizontal: false, vertical: !wideTiles)
        }
    }
}

/// One tile: its name and its figure, then what `picture` draws under them,
/// or beside them when wide. A card a touch see-through over the globe.
private struct OverviewTile<Picture: View>: View {

    let name: LocalizedStringKey
    let figure: String
    let wide: Bool
    let labelWidth: CGFloat
    @ViewBuilder let picture: () -> Picture

    private static var figureFont: Font { .system(size: 16, weight: .medium).monospacedDigit() }
    private static var background: Color { WidgetTheme.card.opacity(0.92) }

    var body: some View {
        Group {
            if wide {
                // centered in the tile whether or not there is a picture
                HStack(spacing: 12) {
                    label
                        .frame(width: labelWidth, alignment: .leading)
                    picture()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    label
                    picture()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(WidgetTheme.caption)
                .foregroundStyle(WidgetTheme.textMuted)
            Text(verbatim: figure)
                .font(Self.figureFont)
                .foregroundStyle(WidgetTheme.text)
        }
        .lineLimit(1)
    }
}

/// Today's traffic as bars, one per hour of the day, each its share of the
/// busiest hour's; the hours still ahead stay empty. Decorative: the figure
/// says the total.
private struct TrafficSparkline: View {

    let hours: [Int64]

    private static let gap: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let fractions = WidgetOverview.sparklineFractions(hours)
            let slot = size.width / CGFloat(max(1, fractions.count))
            for (index, fraction) in fractions.enumerated() where 0 < fraction {
                let height = size.height * CGFloat(fraction)
                let bar = CGRect(
                    x: CGFloat(index) * slot, y: size.height - height,
                    width: max(1, slot - Self.gap), height: height
                )
                context.fill(Path(bar), with: .color(WidgetTheme.byteSeries))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Contracts widget's identity, drawn by its own row: the send stack →
/// in green over the receive stack ← in pink, one circle per contract that
/// fits. Hidden, the same room stays empty, so the tile keeps its size.
private struct ContractStacks: View {

    let overview: WidgetOverview
    let compact: Bool

    private static let rowSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            if let send = overview.send, let receive = overview.receive {
                let capacity = ContractStackRow.capacity(width: geometry.size.width, compact: compact)
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ContractStackRow(
                        contracts: Array(send.prefix(capacity)), byteCount: overview.sendByteCount,
                        color: WidgetTheme.sendStack, arrow: "arrow.right", compact: compact
                    )
                    // every contract, not only the circles that fit
                    .accessibilityLabel(Text("\(send.count) contracts, \(formatByteCountCompact(overview.sendByteCount))"))
                    ContractStackRow(
                        contracts: Array(receive.prefix(capacity)), byteCount: overview.receiveByteCount,
                        color: WidgetTheme.receiveStack, arrow: "arrow.left", compact: compact
                    )
                    .accessibilityLabel(Text("\(receive.count) contracts, \(formatByteCountCompact(overview.receiveByteCount))"))
                }
            }
        }
        .frame(height: 2 * ContractStackRow.slot(compact: compact) + Self.rowSpacing)
    }
}

#if DEBUG
extension SnapshotEntry {
    /// The gallery's sample with the tunnel down: the globe dims, the balance
    /// stays, and traffic and contracts read "—".
    static func sampleDisconnected(at date: Date) -> SnapshotEntry {
        SnapshotEntry(
            date: date,
            tunnel: WidgetSnapshotSample.tunnel(at: date),
            balance: WidgetSnapshotSample.balance(at: date),
            isOn: false, isConfigured: true, isPreview: true
        )
    }
}

#Preview("Connected", as: .systemLarge) {
    OverviewWidget()
} timeline: {
    SnapshotEntry.sample(at: Date())
}

#Preview("Slow", as: .systemLarge) {
    OverviewWidget()
} timeline: {
    SnapshotEntry.sampleSlow(level: 3, upDelayMillis: 800, downDelayMillis: 1900)
}

#Preview("Disconnected", as: .systemLarge) {
    OverviewWidget()
} timeline: {
    SnapshotEntry.sampleDisconnected(at: Date())
}

#Preview("Extra large", as: .systemExtraLarge) {
    OverviewWidget()
} timeline: {
    SnapshotEntry.sample(at: Date())
    SnapshotEntry.sampleSlow(level: 2, upDelayMillis: 420, downDelayMillis: 1100, fallback: true)
    SnapshotEntry.sampleDisconnected(at: Date())
}
#endif
