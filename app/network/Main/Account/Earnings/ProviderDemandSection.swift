//
//  ProviderDemandSection.swift
//  URnetwork
//
//  The "Demand" plot of the provider statistics (P008): how often the
//  network offered this device to clients per minute over the last hour,
//  with an expandable "Why?" that lists the numbers the provider search ranks
//  this device by. It sits after the other provider plots and shows under the
//  same gate.
//

import SwiftUI

/// The "Demand" plot and its "Why?" panel, from the provider status snapshot.
struct ProviderDemandSection: View {

    @EnvironmentObject var themeManager: ThemeManager

    let snapshot: ProviderStatusSnapshot

    // the chart height of the secondary provider plots
    private let chartHeight: CGFloat = 64

    @State private var whyExpanded = false

    var body: some View {
        let presentation = snapshot.presentation

        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .firstTextBaseline) {
                // styled like the other provider plot titles
                Text("Demand")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                Spacer()
                if case .histogram(let histogram) = presentation.area {
                    Text(histogram.totalText)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }

            Text("Times clients were offered this device, per minute, last hour")
                .font(.system(size: 10))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 6)

            switch presentation.area {
            case .loading:
                placeholder(Text("Loading..."))
            case .unavailable:
                placeholder(Text("Provider status isn't available right now."))
            case .histogram(let histogram):
                chart(histogram)
            case .hidden:
                // the provider statistics leave the section out
                EmptyView()
            }

            if presentation.showsWhy {
                Spacer().frame(height: 8)
                why
            }
        }
    }

    /// What shows in place of the chart, at the chart's height so the layout
    /// does not jump when the bars arrive.
    private func placeholder(_ text: Text) -> some View {
        text
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .frame(maxWidth: .infinity, minHeight: chartHeight)
    }

    /// The bars of the last hour, the note when they are all empty, and the
    /// time axis under them.
    private func chart(_ histogram: ProviderDemandHistogram) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProviderDemandBars(
                fractions: histogram.fractions,
                barColor: .urGreen,
                baselineColor: themeManager.currentTheme.borderBaseColor
            )
            .frame(height: chartHeight)
            .overlay {
                if histogram.isEmpty {
                    Text("Not offered to clients in the last hour")
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.center)
                }
            }

            HStack {
                Text("60 min ago")
                Spacer()
                Text("Now")
            }
            .font(.system(size: 10))
            .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Times clients were offered this device, per minute, last hour"))
        .accessibilityValue(Text(histogram.totalText))
    }

    /// The "Why?" disclosure, collapsed by default. A button, so a tap
    /// expands it rather than opening the provider contracts.
    private var why: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                whyExpanded.toggle()
            }) {
                HStack(spacing: 4) {
                    // one catalog entry with the data info sheet's "Why?"
                    Text("Why?")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .rotationEffect(.degrees(whyExpanded ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if whyExpanded {
                let rows = providerStatusRows(numbers: snapshot.numbers, country: snapshot.country)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Spacer().frame(height: 8)
                        ProviderStatusRowView(row: row)
                    }
                }
                // reading the numbers does not open the provider contracts
                .contentShape(Rectangle())
                .onTapGesture {}
            }
        }
    }
}

/// One number of the "Why?" panel: the label and the value, amber when it
/// does not pass, over a muted help line.
private struct ProviderStatusRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: ProviderStatusRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.label)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                Text(verbatim: row.value)
                    .font(themeManager.currentTheme.secondaryBodyFont.monospacedDigit())
                    .foregroundColor(row.passes ? themeManager.currentTheme.textColor : .urAmber)
                    .multilineTextAlignment(.trailing)
            }
            Text(row.help)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 60 bars, oldest on the left, over the 1 pt baseline of the transfer
/// charts' axis. A zero is no bar; the last bar, the current partial minute,
/// is drawn lighter.
private struct ProviderDemandBars: View {

    let fractions: [Double]
    let barColor: Color
    let baselineColor: Color

    var body: some View {
        Canvas { context, size in
            let baselineHeight: CGFloat = 1
            let plotHeight = max(size.height - baselineHeight, 0)
            context.fill(
                Path(CGRect(x: 0, y: plotHeight, width: size.width, height: baselineHeight)),
                with: .color(baselineColor)
            )
            guard !fractions.isEmpty else {
                return
            }
            let slot = size.width / CGFloat(fractions.count)
            let gap = min(1, slot / 4)
            for (i, fraction) in fractions.enumerated() where 0 < fraction {
                let height = max(CGFloat(fraction) * plotHeight, 1)
                let rect = CGRect(
                    x: CGFloat(i) * slot + gap / 2,
                    y: plotHeight - height,
                    width: max(slot - gap, 0.5),
                    height: height
                )
                let partial = i == fractions.count - 1
                context.fill(Path(rect), with: .color(barColor.opacity(partial ? 0.5 : 1)))
            }
        }
    }
}
