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

/// One peer: its short client id and total rate, then the send stack (green,
/// newest first) and the receive stack (pink, newest first) as rows of
/// circles. Width follows the number of circles, which is what makes the
/// cards flow.
struct ContractPeerCard: View {

    let peer: WidgetContractPeerSnapshot
    let compact: Bool

    private static let idLength = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(peer.id.prefix(Self.idLength)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(WidgetTheme.text)
                    .lineLimit(1)
                if 0 < peer.bitRate {
                    Text(formatBitRate(Int(clamping: peer.bitRate)))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(WidgetTheme.textMuted)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                ContractStackRow(
                    contracts: peer.send, byteCount: peer.sendByteCount,
                    color: WidgetTheme.sendStack, arrow: "arrow.right", compact: compact
                )
                ContractStackRow(
                    contracts: peer.receive, byteCount: peer.receiveByteCount,
                    color: WidgetTheme.receiveStack, arrow: "arrow.left", compact: compact
                )
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(WidgetTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

/// A stack drawn horizontally: the direction arrow, then one circle per
/// contract, newest first. Circle area follows the contract's total against
/// the stack's largest, the inner disc is the used fraction, active
/// contracts draw a brighter ring, stream contracts a second outer ring,
/// as in the app's ContractBlock.
struct ContractStackRow: View {

    let contracts: [WidgetContractSnapshot]
    let byteCount: Int64
    let color: Color
    let arrow: String
    let compact: Bool

    private var slot: CGFloat { compact ? 14 : 18 }
    private var minimumDiameter: CGFloat { compact ? 6 : 8 }
    private static let streamRingGap: CGFloat = 1.5

    private var stackMax: Int64 {
        contracts.map(\.totalByteCount).max() ?? 0
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(color)
            if contracts.isEmpty {
                Circle()
                    .stroke(color.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: minimumDiameter, height: minimumDiameter)
                    .frame(width: slot, height: slot)
            } else {
                ForEach(contracts) { contract in
                    circle(contract)
                }
            }
        }
        .accessibilityLabel(Text("\(contracts.count) contracts, \(formatByteCountCompact(byteCount))"))
    }

    private func circle(_ contract: WidgetContractSnapshot) -> some View {
        let diameter: CGFloat = {
            guard 0 < stackMax, 0 < contract.totalByteCount else { return minimumDiameter }
            let d = slot * sqrt(Double(contract.totalByteCount) / Double(stackMax))
            return max(minimumDiameter, min(slot, d))
        }()
        let fraction = 0 < contract.totalByteCount
            ? min(1, Double(contract.usedByteCount) / Double(contract.totalByteCount))
            : 0
        let innerSize = 0 < fraction ? max(2, diameter * sqrt(fraction)) : 0
        let ringColor = color.opacity(contract.isActive ? 1 : 0.55)
        let ringWidth: CGFloat = contract.isActive ? 1.25 : 0.75
        return ZStack {
            if contract.hasStream {
                Circle()
                    .stroke(ringColor, lineWidth: ringWidth)
                    .frame(width: diameter + 2 * Self.streamRingGap, height: diameter + 2 * Self.streamRingGap)
            }
            Circle()
                .stroke(ringColor, lineWidth: ringWidth)
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(color.opacity(0.3))
                .overlay(Circle().stroke(color.opacity(0.6), lineWidth: 0.5))
                .frame(width: innerSize, height: innerSize)
        }
        .frame(width: slot, height: slot)
    }
}

/// Left-to-right, wrapping placement that stops at the bottom edge: cards
/// that would start below it are parked out of bounds (a widget is a
/// static render, so the layout is the only place that knows how many fit).
struct ContractFlowLayout: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        let parked = CGPoint(x: bounds.minX - 10_000, y: bounds.minY - 10_000)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if bounds.maxX < x + size.width, bounds.minX < x {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            guard y + size.height <= bounds.maxY, x + size.width <= bounds.maxX + 0.5 else {
                subview.place(at: parked, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
