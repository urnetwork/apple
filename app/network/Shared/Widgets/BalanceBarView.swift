//
//  BalanceBarView.swift
//  URnetwork
//
//  The dashboard widget's transfer balance bar. Compiled into the app and
//  the widget extension: the app's Account > Widgets screen draws the
//  widget preview with this very view.
//

import SwiftUI

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
